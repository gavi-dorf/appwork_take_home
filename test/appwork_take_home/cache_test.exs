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

  describe "basic functionality" do
    test "fetch returns the upstream response" do
      req = %Request{params: %{id: 1}}
      {:ok, cache} = Cache.start_link(cap: 10, upstream: FastUpstream)

      assert %Response{data: %{id: 1}} = Cache.fetch(cache, req)
    end

    test "repeated fetch returns the cached response" do
      req = %Request{params: %{id: 2}}
      {:ok, cache} = Cache.start_link(cap: 10, upstream: FastUpstream)

      first = Cache.fetch(cache, req)
      second = Cache.fetch(cache, req)
      assert first == second
    end
  end

  describe "LRU eviction" do
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

    test "touch of an already-evicted key is a harmless no-op" do
      # Exercises the empty-lookup branch in handle_call({:touch, key})
      # This race can occur when a process reads an entry from ETS
      # and then another process evicts that entry before the :touch call arrives
      # at the GenServer.  We test both the deterministic path (direct GenServer
      # call) and a probabilistic stress path.

      # Part 1: deterministic — directly touch a key that was never inserted.
      {:ok, cache} = Cache.start_link(cap: 2, upstream: SpyUpstream)
      assert GenServer.call(cache, {:touch, :nonexistent_key}) == :ok

      # Part 2: stress — rapidly alternate two keys with cap=1 to provoke
      # the race between concurrent ETS reads and serialized evictions.
      {:ok, cache2} = Cache.start_link(cap: 1, upstream: SpyUpstream)

      req_a = %Request{params: %{id: :race_a, spy: self()}}
      req_b = %Request{params: %{id: :race_b, spy: self()}}

      for _ <- 1..100 do
        Task.async(fn -> Cache.fetch(cache2, req_a) end)
        Task.async(fn -> Cache.fetch(cache2, req_b) end)
      end
      |> Enum.each(&Task.await/1)

      # If the no-op branch crashed, we would never reach this point.
      drain_count(:upstream_called)
      assert true
    end
  end

  describe "concurrency" do
    test "100 concurrent requests prove both concurrency and caching" do
      n = 100
      upstream = DelayedUpstream
      upstream_latency_ms = upstream.delay_ms()
      requests = Enum.map(1..n, fn i -> %Request{params: %{n: i}} end)

      {:ok, cache} = Cache.start_link(cap: n, upstream: DelayedUpstream)

      # Phase 1: all unique (cache misses) — proves concurrency.
      # Sequential baseline: n × upstream_latency_ms = 10,000ms.
      # Concurrent: ≈ upstream_latency_ms = 100ms.
      t1 = System.monotonic_time(:millisecond)

      requests
      |> Task.async_stream(&Cache.fetch(cache, &1), max_concurrency: n, timeout: 30_000)
      |> Stream.run()

      elapsed1 = System.monotonic_time(:millisecond) - t1

      # Phase 2: same requests (all cache hits) — proves caching.
      # No upstream calls → near-instant.
      t2 = System.monotonic_time(:millisecond)

      requests
      |> Task.async_stream(&Cache.fetch(cache, &1), max_concurrency: n, timeout: 30_000)
      |> Stream.run()

      elapsed2 = System.monotonic_time(:millisecond) - t2

      # n parallel upstream calls ≈ 1× latency, not n× latency.
      assert elapsed1 < upstream_latency_ms * 5,
             "Concurrency: expected ~#{upstream_latency_ms}ms, got #{elapsed1}ms"

      # n cache hits produce no upstream calls → well under one upstream latency.
      assert elapsed2 < div(upstream_latency_ms, 2),
             "Caching: expected near-instant, got #{elapsed2}ms"
    end

    test "concurrent misses on the same key all return the correct response and leave the key cached" do
      # The GenServer deduplicates concurrent puts for the same key via the
      # ets.member check in handle_call({:put}).  This test verifies that
      # (a) every concurrent caller gets the correct response, and
      # (b) the key is properly cached afterwards — no crash, no corruption.
      {:ok, cache} = Cache.start_link(cap: 10, upstream: SpyUpstream)
      req = %Request{params: %{id: :shared, spy: self()}}
      n = 5000

      results =
        1..n
        |> Task.async_stream(fn _ -> Cache.fetch(cache, req) end,
          max_concurrency: n,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      me = self()
      assert Enum.all?(results, &match?(%Response{data: %{id: :shared, spy: ^me}}, &1))

      # We can't check exactly how many upstream calls were made (could be anywhere from 1 to n depending on timing)
      drain_count(:upstream_called)

      # The key must now be cached — no further upstream call.
      Cache.fetch(cache, req)
      refute_received {:upstream_called, _}, "subsequent fetch must be a cache hit"
    end

    test "concurrent misses on different keys exceeding capacity" do
      # Many concurrent first-fetches for distinct keys when total keys > capacity.
      # Multiple concurrent puts arriving at the GenServer can each trigger
      # eviction.  Tests that eviction remains correct under concurrent pressure.
      cap = 5
      n = 20
      {:ok, cache} = Cache.start_link(cap: cap, upstream: SpyUpstream)

      requests = Enum.map(1..n, fn i -> %Request{params: %{id: {:conc, i}, spy: self()}} end)

      # All concurrent misses
      results =
        requests
        |> Task.async_stream(&Cache.fetch(cache, &1), max_concurrency: n, timeout: 5_000)
        |> Enum.map(fn {:ok, result} -> result end)

      # All must return the correct response
      for {req, result} <- Enum.zip(requests, results) do
        assert %Response{data: data} = result
        assert data == req.params
      end

      # All n keys should have triggered upstream calls
      initial_calls = drain_count(:upstream_called)
      assert initial_calls == n, "expected #{n} initial upstream calls, got #{initial_calls}"

      # After all concurrent puts + evictions, exactly `cap` entries must remain.
      # Access the ETS table via persistent_term to check size directly, avoiding
      # cascading evictions that sequential re-fetches would cause.
      %{table: table} = :persistent_term.get({Cache, cache})
      size = :ets.info(table, :size)

      assert size == cap,
             "expected #{cap} entries in cache after #{n} concurrent inserts, got #{size}"
    end
  end

  describe "TTL expiration" do
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

      refute_received {:upstream_called, _},
                      "entry with 60s TTL should still be cached on third fetch"
    end

    test "concurrent re-fetches of the same expired entry all succeed without crash" do
      # When multiple processes discover the same expired entry simultaneously,
      # they all call upstream.fetch then GenServer.call(:put).  The :put handler
      # must handle the duplicate puts gracefully (via the ets.member branch).
      {:ok, cache} = Cache.start_link(cap: 10, upstream: TTLSpyUpstream)
      req = %Request{params: %{id: :ttl_race, spy: self(), ttl: 1}}

      # miss → cached with ttl=1s
      Cache.fetch(cache, req)
      assert_received {:upstream_called, %{id: :ttl_race}}

      # wait for expiry
      Process.sleep(1_100)

      # launch N concurrent fetches — all see the expired entry
      n = 20

      results =
        1..n
        |> Task.async_stream(fn _ -> Cache.fetch(cache, req) end,
          max_concurrency: n,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # all callers must get the correct response
      assert Enum.all?(
               results,
               &(&1 == %Response{data: %{id: :ttl_race, spy: self(), ttl: 1}, ttl: 1})
             )

      # the entry must be properly cached afterwards
      drain_count(:upstream_called)
      Cache.fetch(cache, req)
      refute_received {:upstream_called, _}, "entry should be cached after concurrent re-fetches"
    end

    test "expired entry re-fetch at capacity interacts correctly with LRU eviction" do
      # A full cache where one entry expires.  Re-fetching the expired entry
      # updates it in place (key already exists in ETS), so no eviction occurs.
      # A subsequent new key insert must evict the true LRU (the untouched entry).
      {:ok, cache} = Cache.start_link(cap: 2, upstream: TTLSpyUpstream)

      req_a = %Request{params: %{id: :mix_a, spy: self(), ttl: 1}}
      req_b = %Request{params: %{id: :mix_b, spy: self(), ttl: 60}}

      # miss: cache [A(ttl=1s), B(ttl=60s)]
      Cache.fetch(cache, req_a)
      Cache.fetch(cache, req_b)
      assert_received {:upstream_called, %{id: :mix_a}}
      assert_received {:upstream_called, %{id: :mix_b}}

      # wait for A to expire
      Process.sleep(1_100)

      # A is expired → re-fetch → :put updates A in place (no eviction since key exists)
      Cache.fetch(cache, req_a)
      assert_received {:upstream_called, %{id: :mix_a}}

      # A's counter was refreshed by the :put, so B is now the LRU.
      # Insert C → evicts B (LRU)
      req_c = %Request{params: %{id: :mix_c, spy: self(), ttl: 60}}
      Cache.fetch(cache, req_c)
      assert_received {:upstream_called, %{id: :mix_c}}

      # A should be cached (was just re-fetched)
      Cache.fetch(cache, req_a)
      refute_received {:upstream_called, _}, "A should be cached after re-fetch"

      # C should be cached (just inserted)
      Cache.fetch(cache, req_c)
      refute_received {:upstream_called, _}, "C should be cached"

      # B should have been evicted (it was the LRU when C was inserted)
      Cache.fetch(cache, req_b)

      assert_received {:upstream_called, %{id: :mix_b}},
                      "B should have been evicted as LRU when C was inserted"
    end

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
end
