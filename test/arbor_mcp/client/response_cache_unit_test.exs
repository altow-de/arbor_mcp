defmodule Arbor.MCP.Client.ResponseCacheUnitTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.ResponseCache

  defp pending?(_id), do: true

  defp kept(cache, key, result, now \\ 0) do
    cache
    |> ResponseCache.track(:id, key, &pending?/1)
    |> ResponseCache.store(:id, {:ok, result}, now)
  end

  test "only list pages and resource reads are cacheable, and not MRTR retries" do
    assert ResponseCache.key("tools/list", %{}) == {"tools/list", nil}
    assert ResponseCache.key("prompts/list", %{"cursor" => "c"}) == {"prompts/list", "c"}
    assert ResponseCache.key("resources/read", %{"uri" => "u"}) == {"resources/read", "u"}
    assert ResponseCache.key("tools/call", %{"name" => "t"}) == nil
    assert ResponseCache.key("resources/read", %{"uri" => "u", "requestState" => "s"}) == nil
    assert ResponseCache.key("tools/list", %{"inputResponses" => %{}}) == nil
  end

  test "ttlMs decides freshness, capped at a day; zero, negative or absent isn't kept" do
    cache = ResponseCache.new([])
    key = {"tools/list", nil}

    fresh = kept(cache, key, %{"tools" => [], "ttlMs" => 100})
    assert {:ok, _} = ResponseCache.lookup(fresh, key, 99)
    assert :miss = ResponseCache.lookup(fresh, key, 100)

    capped = kept(cache, key, %{"tools" => [], "ttlMs" => 10 * 86_400_000})
    assert :miss = ResponseCache.lookup(capped, key, 86_400_000)

    for ttl <- [0, -5, nil] do
      result = if ttl, do: %{"tools" => [], "ttlMs" => ttl}, else: %{"tools" => []}
      assert :miss = ResponseCache.lookup(kept(cache, key, result), key, 0)
    end
  end

  test "the client's default applies to a result without ttlMs" do
    cache = ResponseCache.new(default_cache_ttl_ms: 50)
    key = {"tools/list", nil}
    assert {:ok, _} = ResponseCache.lookup(kept(cache, key, %{"tools" => []}), key, 10)
  end

  test "a request that wasn't tracked, or failed, keeps nothing" do
    cache = ResponseCache.new([])
    key = {"tools/list", nil}

    untracked = ResponseCache.store(cache, :other, {:ok, %{"ttlMs" => 100}}, 0)
    assert :miss = ResponseCache.lookup(untracked, key, 0)

    failed =
      cache
      |> ResponseCache.track(:id, key, &pending?/1)
      |> ResponseCache.store(:id, {:error, :boom}, 0)

    assert failed.pending == %{}
  end

  test "the oldest results go past the limit" do
    cache = %{ResponseCache.new([]) | max_entries: 2}

    cache =
      Enum.reduce(1..3, cache, fn n, cache ->
        kept(cache, {"resources/read", "u#{n}"}, %{"contents" => [], "ttlMs" => 100})
      end)

    assert :miss = ResponseCache.lookup(cache, {"resources/read", "u1"}, 0)
    assert {:ok, _} = ResponseCache.lookup(cache, {"resources/read", "u3"}, 0)
  end

  test "tracking drops settled requests" do
    cache =
      ResponseCache.new([])
      |> ResponseCache.track(:a, {"tools/list", nil}, &pending?/1)
      |> ResponseCache.track(:b, {"tools/list", nil}, &(&1 == :b))

    assert Map.keys(cache.pending) == [:b]
  end

  test "a resources list change drops resource and template lists, not reads" do
    cache =
      ResponseCache.new([])
      |> kept({"resources/list", nil}, %{"ttlMs" => 100})
      |> kept({"resources/templates/list", nil}, %{"ttlMs" => 100})
      |> kept({"resources/read", "u"}, %{"ttlMs" => 100})
      |> ResponseCache.invalidate("notifications/resources/list_changed", %{})

    assert :miss = ResponseCache.lookup(cache, {"resources/list", nil}, 0)
    assert :miss = ResponseCache.lookup(cache, {"resources/templates/list", nil}, 0)
    assert {:ok, _} = ResponseCache.lookup(cache, {"resources/read", "u"}, 0)
  end

  test "a disabled cache neither tracks nor answers" do
    cache = ResponseCache.new(response_cache: false)
    key = {"tools/list", nil}
    assert kept(cache, key, %{"ttlMs" => 100}).entries == %{}
    assert :miss = ResponseCache.lookup(cache, key, 0)
  end
end
