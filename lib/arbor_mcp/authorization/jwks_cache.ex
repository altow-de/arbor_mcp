defmodule Arbor.MCP.Authorization.JWKSCache do
  @moduledoc false
  # Keys from authorization servers' JWKS documents, for checking JWT access
  # tokens locally (see JWTVerifier).
  #
  # A key set is kept for `:jwks_cache_ttl_ms` (default ten minutes). A token
  # the held keys don't verify fetches the set again, so a rotated key is
  # picked up; but no set is fetched more than once per `:jwks_min_refresh_ms`
  # (default a minute), whether the last try worked or failed, so made-up key
  # ids, forged signatures or an unreachable server can't make every request
  # fetch. While fetching fails, the last set fetched keeps being used for
  # `:jwks_max_stale_ms` (default an hour), as other JWT libraries do.
  #
  # A set is kept per URL and per fetch policy (`:oauth_http`), so keys a
  # laxer policy fetched never answer for a stricter one. Reads come from
  # ETS; fetches go through this process, so callers waiting on a set share
  # one fetch.

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
    case lookup(cache_key(uri, opts)) do
      %{keys: [_ | _] = keys, fetched_at: fetched_at} ->
        if fresh?(fetched_at, opts), do: {:ok, keys}, else: fetch(uri, opts, :expired)

      _none ->
        fetch(uri, opts, :expired)
    end
  end

  @doc false
  # The key set at `uri` again, for a token the held keys don't verify.
  @spec refresh(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def refresh(uri, opts), do: fetch(uri, opts, :refresh)

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
    key = cache_key(uri, opts)
    entry = lookup(key)

    reply =
      cond do
        # Another caller fetched it while this one waited.
        why == :expired and held_fresh?(entry, opts) ->
          {:ok, entry.keys}

        entry != nil and now() - entry.attempted_at < option(opts, :jwks_min_refresh_ms) ->
          held(entry, opts)

        true ->
          fetch_and_store(key, uri, opts, entry)
      end

    {:reply, reply, state}
  end

  defp fetch_and_store(key, uri, opts, entry) do
    now = now()

    case JWT.fetch_jwks(uri, fetch_options(opts)) do
      {:ok, keys} ->
        :ets.insert(@table, {key, %{keys: keys, fetched_at: now, attempted_at: now}})
        {:ok, keys}

      {:error, reason} ->
        Logger.warning("Could not fetch a JWKS", reason: inspect(reason))

        entry = %{
          keys: entry && entry.keys,
          fetched_at: entry && entry.fetched_at,
          attempted_at: now
        }

        :ets.insert(@table, {key, entry})
        held(entry, opts)
    end
  end

  # The last set fetched, while it isn't too old to trust.
  defp held(%{keys: [_ | _] = keys, fetched_at: fetched_at}, opts) do
    if now() - fetched_at < option(opts, :jwks_max_stale_ms),
      do: {:ok, keys},
      else: {:error, :jwks_unavailable}
  end

  defp held(_entry, _opts), do: {:error, :jwks_unavailable}

  defp held_fresh?(%{keys: [_ | _], fetched_at: fetched_at}, opts), do: fresh?(fetched_at, opts)
  defp held_fresh?(_entry, _opts), do: false

  defp fresh?(fetched_at, opts), do: now() - fetched_at < option(opts, :jwks_cache_ttl_ms)

  defp cache_key(uri, opts), do: {uri, :erlang.phash2(fetch_options(opts))}

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
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
