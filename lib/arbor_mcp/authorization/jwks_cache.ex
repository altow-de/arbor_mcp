defmodule Arbor.MCP.Authorization.JWKSCache do
  @moduledoc false
  # Keys from authorization servers' JWKS documents, for checking JWT access
  # tokens locally (see JWTVerifier).
  #
  # A key set is kept for `:jwks_cache_ttl_ms` (default ten minutes). A token
  # signed with a key the set lacks fetches it again, at most once per
  # `:jwks_min_refresh_ms` (default a minute), so a rotated key is picked up
  # and made-up key ids can't make the server fetch more often. If fetching
  # fails, the last set fetched keeps being used for `:jwks_max_stale_ms`
  # (default an hour), as other JWT libraries do, so a short outage of the
  # authorization server doesn't refuse every request.
  #
  # Reads come from ETS; fetches go through this process one at a time, so
  # callers waiting on the same set share one fetch.

  use GenServer

  require Logger

  alias Arbor.MCP.Authorization.JWT

  @table __MODULE__
  @defaults [
    jwks_cache_ttl_ms: 600_000,
    jwks_min_refresh_ms: 60_000,
    jwks_max_stale_ms: 3_600_000
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # The key set at `uri`, fetched if it isn't held or has expired.
  @spec keys(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def keys(uri, opts) do
    case lookup(uri) do
      {keys, fetched_at} ->
        if fresh?(fetched_at, opts), do: {:ok, keys}, else: fetch(uri, opts, :expired)

      nil ->
        fetch(uri, opts, :expired)
    end
  end

  @doc false
  # The key set at `uri` again, for a token signed with a key it lacks.
  @spec refresh(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def refresh(uri, opts), do: fetch(uri, opts, :unknown_key)

  @doc false
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch(uri, opts, why) do
    case GenServer.whereis(__MODULE__) do
      nil -> JWT.fetch_jwks(uri, fetch_options(opts))
      pid -> GenServer.call(pid, {:fetch, uri, opts, why}, call_timeout(opts))
    end
  catch
    :exit, _reason -> {:error, :jwks_unavailable}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:fetch, uri, opts, why}, _from, state) do
    # Another caller may have fetched it while this one waited.
    reply =
      case lookup(uri) do
        {keys, fetched_at} ->
          if recent?(fetched_at, why, opts),
            do: {:ok, keys},
            else: fetch_and_store(uri, opts, {keys, fetched_at})

        nil ->
          fetch_and_store(uri, opts, nil)
      end

    {:reply, reply, state}
  end

  defp fetch_and_store(uri, opts, held) do
    case JWT.fetch_jwks(uri, fetch_options(opts)) do
      {:ok, keys} ->
        :ets.insert(@table, {uri, keys, now()})
        {:ok, keys}

      {:error, reason} = error ->
        case held do
          {keys, fetched_at} ->
            if now() - fetched_at < option(opts, :jwks_max_stale_ms) do
              Logger.warning("Could not refresh a JWKS; using the keys fetched before",
                reason: inspect(reason)
              )

              {:ok, keys}
            else
              error
            end

          nil ->
            error
        end
    end
  end

  defp recent?(fetched_at, :expired, opts), do: fresh?(fetched_at, opts)

  defp recent?(fetched_at, :unknown_key, opts),
    do: now() - fetched_at < option(opts, :jwks_min_refresh_ms)

  defp fresh?(fetched_at, opts), do: now() - fetched_at < option(opts, :jwks_cache_ttl_ms)

  defp lookup(uri) do
    case :ets.lookup(@table, uri) do
      [{^uri, keys, fetched_at}] -> {keys, fetched_at}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp fetch_options(opts), do: Keyword.get(opts, :oauth_http, [])

  # Long enough for the fetches queued ahead of this one.
  defp call_timeout(opts) do
    request = Keyword.get(fetch_options(opts), :request_timeout_ms, 5_000)
    4 * request + 5_000
  end

  defp option(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@defaults, key))

  defp now, do: System.monotonic_time(:millisecond)
end
