defmodule Arbor.MCP.Client.ResponseCache do
  @moduledoc false
  # The client's cache of results whose server marked them fresh for a while
  # (`ttlMs`, 2026-07-28 "Caching"), as the TypeScript SDK keeps: each
  # `tools/list`, `prompts/list`, `resources/list` and
  # `resources/templates/list` page under its cursor, and each
  # `resources/read` under its URI.
  #
  # A result is kept only while fresh: for its `ttlMs` (at most a day), or
  # the client's `:default_cache_ttl_ms` when it has none. A list change or
  # a resource update drops what it makes stale, and marks a request for it
  # that is still in flight, so that answer isn't kept either. The cache
  # belongs to one client, so `cacheScope: "private"` results are never
  # shared; the scope is recorded for when that changes.
  #
  # Pure data: the client process owns it and passes the clock in.

  @max_ttl_ms 86_400_000

  @list_methods ["tools/list", "prompts/list", "resources/list", "resources/templates/list"]

  @invalidates %{
    "notifications/tools/list_changed" => ["tools/list"],
    "notifications/prompts/list_changed" => ["prompts/list"],
    "notifications/resources/list_changed" => ["resources/list", "resources/templates/list"]
  }

  defstruct enabled: true,
            default_ttl_ms: 0,
            max_entries: 512,
            entries: %{},
            seq: 0,
            pending: %{}

  @type key :: {String.t(), String.t() | nil}
  @type t :: %__MODULE__{
          enabled: boolean(),
          default_ttl_ms: non_neg_integer(),
          max_entries: pos_integer(),
          entries: %{key() => map()},
          seq: non_neg_integer(),
          pending: %{term() => {key(), :live | :stale}}
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      enabled: Keyword.get(opts, :response_cache, true),
      default_ttl_ms: Keyword.get(opts, :default_cache_ttl_ms, 0)
    }
  end

  @doc false
  # The key a request's result is kept under, or nil for one that isn't
  # cacheable. A retried MRTR request depends on inputs outside the key.
  @spec key(String.t(), term()) :: key() | nil
  def key(method, params) when method in @list_methods do
    params = if is_map(params), do: params, else: %{}
    unless mrtr_retry?(params), do: {method, Map.get(params, "cursor")}
  end

  def key("resources/read", %{"uri" => uri} = params) when is_binary(uri) do
    unless mrtr_retry?(params), do: {"resources/read", uri}
  end

  def key(_method, _params), do: nil

  defp mrtr_retry?(params),
    do: Map.has_key?(params, "inputResponses") or Map.has_key?(params, "requestState")

  @doc false
  @spec lookup(t(), key() | nil, integer()) :: {:ok, map()} | :miss
  def lookup(%__MODULE__{enabled: true, entries: entries}, key, now) when not is_nil(key) do
    case Map.get(entries, key) do
      %{expires_at: expires_at, result: result} when expires_at > now -> {:ok, result}
      _missing_or_stale -> :miss
    end
  end

  def lookup(_cache, _key, _now), do: :miss

  @doc false
  # Remembers that request `id` will answer `key`. Entries for settled
  # requests are dropped here, so the map holds only those still pending.
  @spec track(t(), term(), key() | nil, (term() -> boolean())) :: t()
  def track(%__MODULE__{enabled: true} = cache, id, key, pending?) when not is_nil(key) do
    pending = cache.pending |> Map.filter(fn {other, _} -> pending?.(other) end)
    %{cache | pending: Map.put(pending, id, {key, :live})}
  end

  def track(cache, _id, _key, _pending?), do: cache

  @doc false
  # Keeps request `id`'s result while it's fresh, unless a change made it
  # stale while the request was in flight.
  @spec store(t(), term(), {:ok, map()} | term(), integer()) :: t()
  def store(%__MODULE__{} = cache, id, {:ok, result}, now) when is_map(result) do
    case Map.pop(cache.pending, id) do
      {{key, :live}, pending} ->
        put(%{cache | pending: pending}, key, result, now)

      {_stale_or_untracked, pending} ->
        %{cache | pending: pending}
    end
  end

  def store(%__MODULE__{} = cache, id, _error, _now),
    do: %{cache | pending: Map.delete(cache.pending, id)}

  defp put(cache, key, result, now) do
    ttl =
      case Map.get(result, "ttlMs") do
        ms when is_integer(ms) -> ms |> max(0) |> min(@max_ttl_ms)
        _absent -> cache.default_ttl_ms |> max(0) |> min(@max_ttl_ms)
      end

    if ttl > 0 do
      entry = %{
        result: result,
        expires_at: now + ttl,
        scope: if(Map.get(result, "cacheScope") == "public", do: :public, else: :private),
        seq: cache.seq + 1
      }

      %{cache | entries: Map.put(cache.entries, key, entry), seq: cache.seq + 1}
      |> bound()
    else
      %{cache | entries: Map.delete(cache.entries, key)}
    end
  end

  # Drops the oldest entries past the limit.
  defp bound(%{entries: entries, max_entries: max} = cache) when map_size(entries) <= max,
    do: cache

  defp bound(cache) do
    {oldest, _entry} = Enum.min_by(cache.entries, fn {_key, entry} -> entry.seq end)
    bound(%{cache | entries: Map.delete(cache.entries, oldest)})
  end

  @doc false
  # Drops what a notification makes stale and marks requests in flight for it.
  @spec invalidate(t(), String.t(), term()) :: t()
  def invalidate(%__MODULE__{} = cache, "notifications/resources/updated", %{"uri" => uri})
      when is_binary(uri),
      do: drop(cache, &(&1 == {"resources/read", uri}))

  def invalidate(%__MODULE__{} = cache, notification, _params)
      when is_map_key(@invalidates, notification) do
    methods = Map.fetch!(@invalidates, notification)
    drop(cache, fn {method, _params} -> method in methods end)
  end

  def invalidate(cache, _notification, _params), do: cache

  defp drop(cache, stale?) do
    %{
      cache
      | entries: Map.reject(cache.entries, fn {key, _entry} -> stale?.(key) end),
        pending:
          Map.new(cache.pending, fn {id, {key, state}} ->
            {id, {key, if(stale?.(key), do: :stale, else: state)}}
          end)
    }
  end

  @doc false
  # A new connection may be to a changed server.
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = cache), do: %{cache | entries: %{}, pending: %{}}
end
