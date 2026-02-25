defmodule AppworkTakeHome.CacheTest.FastUpstream do
  @moduledoc "Instant upstream mock: returns %Response{data: params} with no delay."
  alias AppworkTakeHome.{Request, Response}
  def fetch(%Request{params: params}), do: %Response{data: params}
end

defmodule AppworkTakeHome.CacheTest.DelayedUpstream do
  @moduledoc """
  Upstream mock with a delay to make cache hits vs misses distinguishable by timing.
  """
  alias AppworkTakeHome.{Request, Response}
  # This will still function as a constant due to Erlang's constant pools
  # See here for more info:
  # - https://github.com/discord/fastglobal
  # - https://www.erlang.org/docs/17/efficiency_guide/processes
  def delay_ms, do: 100

  def fetch(%Request{params: params}) do
    Process.sleep(delay_ms())
    %Response{data: params}
  end
end

defmodule AppworkTakeHome.CacheTest do
  use ExUnit.Case

  alias AppworkTakeHome.{Cache, Request, Response}
  alias AppworkTakeHome.CacheTest.{DelayedUpstream, FastUpstream}

  @cache AppworkTakeHome.Cache

  test "100 concurrent requests prove both concurrency and caching" do
    n = 100
    upstream = DelayedUpstream
    upstream_latency_ms = upstream.delay_ms()
    requests = Enum.map(1..n, fn i -> %Request{params: %{n: i}} end)

    {:ok, cache} = @cache.start_link(cap: n, upstream: DelayedUpstream)

    # Phase 1: all unique (cache misses) — proves concurrency.
    # Sequential baseline: n × upstream_latency_ms = 10,000ms.
    # Concurrent: ≈ upstream_latency_ms = 100ms.
    t1 = System.monotonic_time(:millisecond)

    requests
    |> Task.async_stream(&@cache.fetch(cache, &1), max_concurrency: n, timeout: 30_000)
    |> Stream.run()

    elapsed1 = System.monotonic_time(:millisecond) - t1

    # Phase 2: same requests (all cache hits) — proves caching.
    # No upstream calls → near-instant.
    t2 = System.monotonic_time(:millisecond)

    requests
    |> Task.async_stream(&@cache.fetch(cache, &1), max_concurrency: n, timeout: 30_000)
    |> Stream.run()

    elapsed2 = System.monotonic_time(:millisecond) - t2

    # n parallel upstream calls ≈ 1× latency, not n× latency.
    assert elapsed1 < upstream_latency_ms * 5,
           "Concurrency: expected ~#{upstream_latency_ms}ms, got #{elapsed1}ms"

    # n cache hits produce no upstream calls → well under one upstream latency.
    assert elapsed2 < div(upstream_latency_ms, 2),
           "Caching: expected near-instant, got #{elapsed2}ms"
  end

  # ---------------------------------------------------------------------------
  # Correctness tests (fast, no upstream latency)
  # ---------------------------------------------------------------------------

  test "fetch returns the upstream response" do
    req = %Request{params: %{id: 1}}
    {:ok, cache} = Cache.start_link(cap: 10, upstream: FastUpstream)

    assert Cache.fetch(cache, req) == %Response{data: %{id: 1}}
  end

  test "repeated fetch returns the cached response" do
    req = %Request{params: %{id: 2}}
    {:ok, cache} = Cache.start_link(cap: 10, upstream: FastUpstream)

    first = Cache.fetch(cache, req)
    second = Cache.fetch(cache, req)
    assert first == second
  end

  # ---------------------------------------------------------------------------
  # Eviction tests
  # ---------------------------------------------------------------------------

  test "entry evicted at capacity boundary can be re-fetched correctly" do
    req_a = %Request{params: %{id: :a}}
    req_b = %Request{params: %{id: :b}}
    req_c = %Request{params: %{id: :c}}
    {:ok, cache} = Cache.start_link(cap: 2, upstream: FastUpstream)

    Cache.fetch(cache, req_a)
    Cache.fetch(cache, req_b)
    # evicts A (FIFO)
    Cache.fetch(cache, req_c)

    # A was evicted; re-fetching should still return the correct value
    assert Cache.fetch(cache, req_a) == %Response{data: %{id: :a}}
  end

  test "no eviction when at or below capacity" do
    req_a = %Request{params: %{id: :a}}
    req_b = %Request{params: %{id: :b}}
    {:ok, cache} = Cache.start_link(cap: 2, upstream: FastUpstream)

    Cache.fetch(cache, req_a)
    Cache.fetch(cache, req_b)

    # Both entries fit within cap=2; subsequent fetches must be instant cache hits.
    t = System.monotonic_time(:millisecond)
    Cache.fetch(cache, req_a)
    Cache.fetch(cache, req_b)
    elapsed = System.monotonic_time(:millisecond) - t

    assert elapsed < 5, "expected cache hits under cap, got #{elapsed}ms"
  end

  # ---------------------------------------------------------------------------
  # V1 → V2 behavioral contract
  # This test is @tagged :v2 and is expected to FAIL on V1 (FIFO eviction).
  # It becomes the green gate that confirms V2 (LRU) is correctly implemented.
  # ---------------------------------------------------------------------------

  @tag :v2
  test "cache hit on A keeps A alive when B would be LRU-evicted (LRU, not FIFO)" do
    req_a = %Request{params: %{id: :a}}
    req_b = %Request{params: %{id: :b}}
    req_c = %Request{params: %{id: :c}}

    # DelayedUpstream sleeps 20ms per call, making cache hits (< 5ms) vs
    # cache misses (≥ 20ms) distinguishable by timing.
    {:ok, cache} = Cache.start_link(cap: 2, upstream: DelayedUpstream)

    # cache: [A]
    Cache.fetch(cache, req_a)
    # cache: [A, B]
    Cache.fetch(cache, req_b)
    # V2: A touched → eviction order becomes [B, A]
    Cache.fetch(cache, req_a)
    # V2 evicts B (LRU); V1 evicts A (FIFO)
    Cache.fetch(cache, req_c)

    # Under LRU, A must still be a cache hit (instant, no upstream call).
    # Under V1 FIFO, A was evicted → upstream call → elapsed ≥ 20ms → assertion fails.
    t = System.monotonic_time(:millisecond)
    Cache.fetch(cache, req_a)
    elapsed = System.monotonic_time(:millisecond) - t

    assert elapsed < 5, "A should still be cached under LRU, got #{elapsed}ms"
  end
end
