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
    assert ResponseCache.key("tools/list", %{}) == {"tools/list", nil, nil}
    assert ResponseCache.key("prompts/list", %{"cursor" => "c"}) == {"prompts/list", "c", nil}
    assert ResponseCache.key("resources/read", %{"uri" => "u"}) == {"resources/read", "u", nil}
    assert ResponseCache.key("tools/call", %{"name" => "t"}) == nil
    assert ResponseCache.key("resources/read", %{"uri" => "u", "requestState" => "s"}) == nil
    assert ResponseCache.key("tools/list", %{"inputResponses" => %{}}) == nil
  end

  test "ttlMs decides freshness, capped at a day; zero, negative or absent isn't kept" do
    cache = ResponseCache.new([])
    key = {"tools/list", nil, nil}

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
    key = {"tools/list", nil, nil}
    assert {:ok, _} = ResponseCache.lookup(kept(cache, key, %{"tools" => []}), key, 10)
  end

  test "a request that wasn't tracked, or failed, keeps nothing" do
    cache = ResponseCache.new([])
    key = {"tools/list", nil, nil}

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
        kept(cache, {"resources/read", "u#{n}", nil}, %{"contents" => [], "ttlMs" => 100})
      end)

    assert :miss = ResponseCache.lookup(cache, {"resources/read", "u1", nil}, 0)
    assert {:ok, _} = ResponseCache.lookup(cache, {"resources/read", "u3", nil}, 0)
  end

  test "tracking drops settled requests" do
    cache =
      ResponseCache.new([])
      |> ResponseCache.track(:a, {"tools/list", nil, nil}, &pending?/1)
      |> ResponseCache.track(:b, {"tools/list", nil, nil}, &(&1 == :b))

    assert Map.keys(cache.pending) == [:b]
  end

  test "a resources list change drops resource and template lists, not reads" do
    cache =
      ResponseCache.new([])
      |> kept({"resources/list", nil, nil}, %{"ttlMs" => 100})
      |> kept({"resources/templates/list", nil, nil}, %{"ttlMs" => 100})
      |> kept({"resources/read", "u", nil}, %{"ttlMs" => 100})
      |> ResponseCache.invalidate("notifications/resources/list_changed", %{})

    assert :miss = ResponseCache.lookup(cache, {"resources/list", nil, nil}, 0)
    assert :miss = ResponseCache.lookup(cache, {"resources/templates/list", nil, nil}, 0)
    assert {:ok, _} = ResponseCache.lookup(cache, {"resources/read", "u", nil}, 0)
  end

  test "application metadata is part of the key; a progress token isn't" do
    plain = ResponseCache.key("tools/list", %{})

    assert ResponseCache.key("tools/list", %{"_meta" => %{"progressToken" => "t"}}) == plain

    assert ResponseCache.key("tools/list", %{
             "_meta" => %{"io.modelcontextprotocol/clientInfo" => %{}}
           }) == plain

    refute ResponseCache.key("tools/list", %{"_meta" => %{"tenant" => "a"}}) == plain
  end

  test "an interim result isn't kept, even under a default TTL" do
    cache = ResponseCache.new(default_cache_ttl_ms: 60_000)
    key = {"resources/read", "u", nil}
    interim = %{"resultType" => "input_required", "inputRequests" => %{}}

    assert :miss = ResponseCache.lookup(kept(cache, key, interim), key, 0)
    assert {:ok, _} = ResponseCache.lookup(kept(cache, key, %{"contents" => []}), key, 0)
  end

  test "results are bounded by size as well as number" do
    cache = %{ResponseCache.new([]) | max_bytes: 3_000, max_entry_bytes: 2_000}
    body = fn n -> %{"contents" => [%{"text" => String.duplicate("x", n)}], "ttlMs" => 100} end

    cache = kept(cache, {"resources/read", "big", nil}, body.(5_000))
    assert :miss = ResponseCache.lookup(cache, {"resources/read", "big", nil}, 0)

    cache =
      cache
      |> kept({"resources/read", "a", nil}, body.(1_500))
      |> kept({"resources/read", "b", nil}, body.(1_500))

    assert :miss = ResponseCache.lookup(cache, {"resources/read", "a", nil}, 0)
    assert {:ok, _} = ResponseCache.lookup(cache, {"resources/read", "b", nil}, 0)
    assert cache.bytes <= 3_000
  end

  test "invalid options are refused" do
    assert_raise ArgumentError, ~r/default_cache_ttl_ms/, fn ->
      ResponseCache.new(default_cache_ttl_ms: "0")
    end

    assert_raise ArgumentError, ~r/response_cache/, fn ->
      ResponseCache.new(response_cache: :yes)
    end
  end

  test "a disabled cache neither tracks nor answers" do
    cache = ResponseCache.new(response_cache: false)
    key = {"tools/list", nil, nil}
    assert kept(cache, key, %{"ttlMs" => 100}).entries == %{}
    assert :miss = ResponseCache.lookup(cache, key, 0)
  end
end
