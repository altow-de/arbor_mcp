defmodule Arbor.MCP.Client.ResponseCache do
  @moduledoc false
  # The client's cache of results whose server marked them fresh for a while
  # (`ttlMs`, 2026-07-28 "Caching"), as the TypeScript SDK keeps: each
  # `tools/list`, `prompts/list`, `resources/list` and
  # `resources/templates/list` page under its cursor, and each
  # `resources/read` under its URI.
  #
  # A complete result is kept only while fresh: for its `ttlMs` (at most a
  # day), or the client's `:default_cache_ttl_ms` when it has none. A list
  # change or a resource update drops what it makes stale, and marks a
  # request for it that is still in flight, so that answer isn't kept
  # either. Application `_meta` on a request is part of its key, as it may
  # change the result. At most 512 results, 16 MiB in all, are kept, and
  # none over 1 MiB. The cache belongs to one client, which has one
  # authorization context, so `cacheScope: "private"` results are never
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
            max_bytes: 16 * 1_024 * 1_024,
            max_entry_bytes: 1_024 * 1_024,
            entries: %{},
            bytes: 0,
            seq: 0,
            pending: %{}

  @type key :: {String.t(), String.t() | nil, map() | nil}
  @type t :: %__MODULE__{
          enabled: boolean(),
          default_ttl_ms: non_neg_integer(),
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          max_entry_bytes: pos_integer(),
          entries: %{key() => map()},
          bytes: non_neg_integer(),
          seq: non_neg_integer(),
          pending: %{term() => {key(), :live | :stale}}
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    enabled = Keyword.get(opts, :response_cache, true)
    default_ttl_ms = Keyword.get(opts, :default_cache_ttl_ms, 0)

    unless is_boolean(enabled),
      do: raise(ArgumentError, "response_cache must be a boolean, got: #{inspect(enabled)}")

    unless is_integer(default_ttl_ms) and default_ttl_ms >= 0,
      do:
        raise(
          ArgumentError,
          "default_cache_ttl_ms must be a non-negative integer, got: #{inspect(default_ttl_ms)}"
        )

    %__MODULE__{enabled: enabled, default_ttl_ms: default_ttl_ms}
  end

  @doc false
  # The key a request's result is kept under, or nil for one that isn't
  # cacheable. A retried MRTR request depends on inputs outside the key.
  @spec key(String.t(), term()) :: key() | nil
  def key(method, params) when method in @list_methods do
    params = if is_map(params), do: params, else: %{}
    unless mrtr_retry?(params), do: {method, Map.get(params, "cursor"), app_meta(params)}
  end

  def key("resources/read", %{"uri" => uri} = params) when is_binary(uri) do
    unless mrtr_retry?(params), do: {"resources/read", uri, app_meta(params)}
  end

  def key(_method, _params), do: nil

  defp mrtr_retry?(params),
    do: Map.has_key?(params, "inputResponses") or Map.has_key?(params, "requestState")

  # A progress token and the protocol's own metadata don't change a result.
  defp app_meta(%{"_meta" => %{} = meta}) do
    meta =
      Map.reject(meta, fn {name, _value} ->
        name in ["progressToken", :progressToken] or
          (is_binary(name) and String.starts_with?(name, "io.modelcontextprotocol/"))
      end)

    if meta == %{}, do: nil, else: meta
  end

  defp app_meta(_params), do: nil

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

  # Only a complete result is cacheable: an input_required one, say, is not.
  defp put(cache, key, %{"resultType" => type}, _now) when type != "complete",
    do: drop(cache, &(&1 == key))

  defp put(cache, key, result, now) do
    ttl =
      case Map.get(result, "ttlMs") do
        ms when is_integer(ms) -> ms |> max(0) |> min(@max_ttl_ms)
        _absent -> cache.default_ttl_ms |> max(0) |> min(@max_ttl_ms)
      end

    size = :erlang.external_size(result)
    cache = remove(cache, key)

    if ttl > 0 and size <= cache.max_entry_bytes do
      entry = %{
        result: result,
        expires_at: now + ttl,
        scope: if(Map.get(result, "cacheScope") == "public", do: :public, else: :private),
        bytes: size,
        seq: cache.seq + 1
      }

      %{
        cache
        | entries: Map.put(cache.entries, key, entry),
          bytes: cache.bytes + size,
          seq: cache.seq + 1
      }
      |> bound()
    else
      cache
    end
  end

  defp remove(cache, key) do
    case Map.pop(cache.entries, key) do
      {nil, _entries} -> cache
      {entry, entries} -> %{cache | entries: entries, bytes: cache.bytes - entry.bytes}
    end
  end

  # Drops the oldest entries past the limits.
  defp bound(%{entries: entries, max_entries: max} = cache)
       when map_size(entries) <= max and cache.bytes <= cache.max_bytes,
       do: cache

  defp bound(cache) do
    {oldest, _entry} = Enum.min_by(cache.entries, fn {_key, entry} -> entry.seq end)
    bound(remove(cache, oldest))
  end

  @doc false
  # Drops what a notification makes stale and marks requests in flight for it.
  @spec invalidate(t(), String.t(), term()) :: t()
  def invalidate(%__MODULE__{} = cache, "notifications/resources/updated", %{"uri" => uri})
      when is_binary(uri),
      do: drop(cache, &match?({"resources/read", ^uri, _meta}, &1))

  def invalidate(%__MODULE__{} = cache, notification, _params)
      when is_map_key(@invalidates, notification) do
    methods = Map.fetch!(@invalidates, notification)
    drop(cache, fn {method, _target, _meta} -> method in methods end)
  end

  def invalidate(cache, _notification, _params), do: cache

  defp drop(cache, stale?) do
    cache =
      cache.entries |> Map.keys() |> Enum.filter(stale?) |> Enum.reduce(cache, &remove(&2, &1))

    %{
      cache
      | pending:
          Map.new(cache.pending, fn {id, {key, state}} ->
            {id, {key, if(stale?.(key), do: :stale, else: state)}}
          end)
    }
  end

  @doc false
  # A new connection may be to a changed server.
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = cache), do: %{cache | entries: %{}, bytes: 0, pending: %{}}
end
