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

defmodule AppworkTakeHome.CacheTest.SpyUpstream do
  @moduledoc """
  Instant upstream mock that notifies a designated listener process on every
  call.  Include `spy: pid` in the request params; the listener receives
  `{:upstream_called, params}` each time this upstream is invoked, enabling
  deterministic hit/miss detection without timing sensitivity.
  """
  alias AppworkTakeHome.{Request, Response}

  def fetch(%Request{params: %{spy: pid} = params}) do
    send(pid, {:upstream_called, params})
    %Response{data: params}
  end
end

defmodule AppworkTakeHome.CacheTest.TTLSpyUpstream do
  @moduledoc """
  Instant upstream mock that returns responses with a TTL field.  The TTL
  value is taken from the request params (`ttl: seconds`), and the spy
  process (`spy: pid`) receives `{:upstream_called, params}` on every call.
  """
  alias AppworkTakeHome.{Request, Response}

  def fetch(%Request{params: %{spy: pid, ttl: ttl} = params}) do
    send(pid, {:upstream_called, params})
    %Response{data: params, ttl: ttl}
  end
end

defmodule AppworkTakeHome.CacheTest do
  use ExUnit.Case

  alias AppworkTakeHome.{Cache, Request, Response}
  alias AppworkTakeHome.CacheTest.{DelayedUpstream, FastUpstream, SpyUpstream, TTLSpyUpstream}

  # Drains all `{tag, _}` messages from the test process mailbox and returns
  # the count.  Uses `after 0` so it never blocks.
  defp drain_count(tag, acc \\ 0) do
    receive do
      {^tag, _} -> drain_count(tag, acc + 1)
    after
      0 -> acc
    end
  end

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

  # ---------------------------------------------------------------------------
  # Additional V2 correctness tests (deterministic, no timing sensitivity)
  # ---------------------------------------------------------------------------

  test "sequential evictions leave no ghost counters in the order table" do
    # With cap=1 each new fetch evicts the previous entry.  If a previous
    # eviction left a ghost counter in order_table, re-inserting A would consume
    # that ghost instead of evicting B, silently leaving both A and B in the
    # cache.  Observable consequence: B would be a hit when it should be a miss.
    {:ok, cache} = Cache.start_link(cap: 1, upstream: SpyUpstream)

    req_a = %Request{params: %{id: :a, spy: self()}}
    req_b = %Request{params: %{id: :b, spy: self()}}

    # miss: insert A, cache [A]
    Cache.fetch(cache, req_a)
    # miss: insert B, evict A, cache [B]
    Cache.fetch(cache, req_b)
    assert_received {:upstream_called, %{id: :a}}
    assert_received {:upstream_called, %{id: :b}}

    # miss: insert A, must evict B, cache [A]
    Cache.fetch(cache, req_a)
    assert_received {:upstream_called, %{id: :a}}

    Cache.fetch(cache, req_b)

    assert_received {:upstream_called, %{id: :b}},
                    "B should have been evicted when A was re-inserted; a ghost counter would prevent this"
  end

  test "concurrent misses on the same key all return the correct response and leave the key cached" do
    # The GenServer deduplicates concurrent puts for the same key via the
    # ets.member check in handle_call({:put}).  This test verifies that
    # (a) every concurrent caller gets the correct response, and
    # (b) the key is properly cached afterwards — no crash, no corruption.
    {:ok, cache} = Cache.start_link(cap: 10, upstream: SpyUpstream)
    req = %Request{params: %{id: :shared, spy: self()}}
    n = 50

    results =
      1..n
      |> Task.async_stream(fn _ -> Cache.fetch(cache, req) end,
        max_concurrency: n,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == %Response{data: %{id: :shared, spy: self()}}))

    # There should only be one upstream call for the shared key, not n calls.
    assert drain_count(:upstream_called) == 1,
           "expected 1 upstream call for concurrent misses on the same key, got multiple"

    # The key must now be cached — no further upstream call.
    Cache.fetch(cache, req)
    refute_received {:upstream_called, _}, "subsequent fetch must be a cache hit"
  end

  test "touching a middle-ordered entry makes the oldest entry the LRU eviction target" do
    # With cap=3 and LRU order A(oldest) < B < C(newest), touching B promotes
    # it to MRU: new order A(LRU) < C < B.  Inserting D must evict A, not B or C.
    {:ok, cache} = Cache.start_link(cap: 3, upstream: SpyUpstream)
    req_a = %Request{params: %{id: :a, spy: self()}}
    req_b = %Request{params: %{id: :b, spy: self()}}
    req_c = %Request{params: %{id: :c, spy: self()}}
    req_d = %Request{params: %{id: :d, spy: self()}}

    # miss
    Cache.fetch(cache, req_a)
    # miss
    Cache.fetch(cache, req_b)
    # miss
    Cache.fetch(cache, req_c)
    for _ <- 1..3, do: assert_received({:upstream_called, _})

    # hit: B becomes MRU; order: A(LRU) < C < B
    Cache.fetch(cache, req_b)

    # miss: insert D, evict A (LRU)
    Cache.fetch(cache, req_d)
    # D call
    assert_received {:upstream_called, %{id: :d}}

    # Check hits first: a hit only touches the entry (no eviction), so checking
    # B and C does not change the cache size or evict anything.
    Cache.fetch(cache, req_b)
    refute_received {:upstream_called, _}, "B should still be cached (was touched)"

    Cache.fetch(cache, req_c)
    refute_received {:upstream_called, _}, "C should still be cached (newer than A)"

    # Check the miss last: re-inserting A will evict the current LRU (D by this
    # point, since B and C were just touched), which is fine — we only care that
    # A itself is a miss.
    Cache.fetch(cache, req_a)

    assert_received {:upstream_called, %{id: :a}},
                    "A should have been evicted (it was the LRU when D was inserted)"
  end

  test "touching the oldest entry saves it; the second-oldest becomes the new LRU" do
    # With cap=2 and order A(LRU) < B, touching A makes B the new LRU.
    # Inserting C must then evict B, not A.
    # Complements the timing-based :v2 test with a deterministic spy approach
    # that also explicitly verifies B was evicted (not just that A survived).
    {:ok, cache} = Cache.start_link(cap: 2, upstream: SpyUpstream)
    req_a = %Request{params: %{id: :a, spy: self()}}
    req_b = %Request{params: %{id: :b, spy: self()}}
    req_c = %Request{params: %{id: :c, spy: self()}}

    # miss
    Cache.fetch(cache, req_a)
    # miss
    Cache.fetch(cache, req_b)
    for _ <- 1..2, do: assert_received({:upstream_called, _})

    # hit: A (LRU) becomes MRU; order: B(LRU) < A
    Cache.fetch(cache, req_a)

    # miss: insert C, evict B (LRU)
    Cache.fetch(cache, req_c)
    # C call
    assert_received {:upstream_called, %{id: :c}}

    # Check A first (while it is definitely still in cache).
    Cache.fetch(cache, req_a)
    refute_received {:upstream_called, _}, "A should still be cached (was touched)"

    Cache.fetch(cache, req_b)

    assert_received {:upstream_called, %{id: :b}},
                    "B should have been evicted (it became LRU when A was touched)"
  end

  test "repeated touches keep an entry alive through many eviction rounds" do
    # With cap=2, priming A then repeatedly touching A before each new insert
    # must keep A in cache indefinitely: the touch makes A the MRU so the
    # newcomer from the previous round is always the LRU that gets evicted.
    {:ok, cache} = Cache.start_link(cap: 2, upstream: SpyUpstream)
    req_a = %Request{params: %{id: :a, spy: self()}}

    # prime A; 1 upstream call
    Cache.fetch(cache, req_a)
    assert_received {:upstream_called, %{id: :a}}

    for i <- 1..10 do
      req_new = %Request{params: %{id: {:new, i}, spy: self()}}
      # hit: A becomes MRU
      Cache.fetch(cache, req_a)
      # miss: insert newcomer, evict previous
      Cache.fetch(cache, req_new)
    end

    # 10 newcomer misses; the 10 A touches were all hits.
    for _ <- 1..10, do: assert_received({:upstream_called, %{id: {:new, _}}})

    Cache.fetch(cache, req_a)

    refute_received {:upstream_called, _},
                    "A should still be cached after 10 eviction rounds of repeated touches"
  end

  # ---------------------------------------------------------------------------
  # V2 → V3 behavioral contract
  # These tests are @tagged :v3 and are expected to FAIL on V2 (no TTL).
  # They become the green gate that confirms V3 (LRU + TTL) is correctly
  # implemented.
  # ---------------------------------------------------------------------------

  @tag :v3
  test "expired entry is re-fetched from upstream" do
    # Core TTL test: after the TTL elapses, the cached response must be
    # treated as invalid and the upstream must be called again.
    {:ok, cache} = Cache.start_link(cap: 10, upstream: TTLSpyUpstream)
    req = %Request{params: %{id: :ttl_basic, spy: self(), ttl: 1}}

    # miss: upstream called, response cached with ttl=1s
    Cache.fetch(cache, req)
    assert_received {:upstream_called, %{id: :ttl_basic}}

    # hit: within TTL window
    Cache.fetch(cache, req)
    refute_received {:upstream_called, _}, "should be a cache hit before TTL expires"

    # wait for TTL to expire
    Process.sleep(1_100)

    # miss: TTL expired, upstream must be called again
    Cache.fetch(cache, req)

    assert_received {:upstream_called, %{id: :ttl_basic}},
                    "expired entry should trigger an upstream re-fetch"
  end

  @tag :v3
  test "non-expired entry is served from cache (TTL does not break normal hits)" do
    # With a long TTL, the entry must remain a cache hit — TTL support
    # must not accidentally invalidate every entry.
    {:ok, cache} = Cache.start_link(cap: 10, upstream: TTLSpyUpstream)
    req = %Request{params: %{id: :long_ttl, spy: self(), ttl: 60}}

    # miss
    Cache.fetch(cache, req)
    assert_received {:upstream_called, %{id: :long_ttl}}

    # hit (well within 60s TTL)
    Cache.fetch(cache, req)
    refute_received {:upstream_called, _}, "entry with 60s TTL should still be cached"

    # hit again
    Cache.fetch(cache, req)
    refute_received {:upstream_called, _}, "entry with 60s TTL should still be cached on third fetch"
  end

  @tag :v3
  test "re-fetched expired entry resets its TTL" do
    # After an expired entry is re-fetched, the new response's TTL
    # applies.  The entry must not immediately expire again.
    {:ok, cache} = Cache.start_link(cap: 10, upstream: TTLSpyUpstream)
    req = %Request{params: %{id: :ttl_reset, spy: self(), ttl: 1}}

    # miss → cached with ttl=1s
    Cache.fetch(cache, req)
    assert_received {:upstream_called, %{id: :ttl_reset}}

    # wait for expiry
    Process.sleep(1_100)

    # miss → re-fetched, new TTL starts now
    Cache.fetch(cache, req)
    assert_received {:upstream_called, %{id: :ttl_reset}}

    Process.sleep(500)

    # after re-fetch, the entry should be a hit (we are still within the TTL)
    Cache.fetch(cache, req)
    refute_received {:upstream_called, _}, "re-fetched entry should have a fresh TTL"
  end
end
