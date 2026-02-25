defmodule AppworkTakeHome.CacheTest do
  use ExUnit.Case

  alias AppworkTakeHome.{Request, SlowUpstream}

  @cache AppworkTakeHome.Cache
  @upstream_latency_ms 100

  test "100 concurrent requests prove both concurrency and caching" do
    n = 100
    requests = Enum.map(1..n, fn i -> %Request{params: %{n: i}} end)

    {:ok, cache} = @cache.start_link(cap: n)

    # Phase 1: all unique (cache misses) — proves concurrency.
    # Sequential baseline: n × @upstream_latency_ms = 10,000ms.
    # Concurrent: ≈ @upstream_latency_ms = 100ms.
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
    assert elapsed1 < @upstream_latency_ms * 5,
           "Concurrency: expected ~#{@upstream_latency_ms}ms, got #{elapsed1}ms"

    # n cache hits produce no upstream calls → well under one upstream latency.
    assert elapsed2 < div(@upstream_latency_ms, 2),
           "Caching: expected near-instant, got #{elapsed2}ms"
  end
end
