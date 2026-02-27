defmodule AppworkTakeHome.CacheTest.FastUpstream do
  @moduledoc "Instant upstream mock: returns %Response{data: params} with no delay."
  @behaviour AppworkTakeHome.Upstream
  alias AppworkTakeHome.{Request, Response}
  def fetch(%Request{params: params}), do: %Response{data: params, ttl: 3600}
end

defmodule AppworkTakeHome.CacheTest.DelayedUpstream do
  @moduledoc """
  Upstream mock with a delay to make cache hits vs misses distinguishable by timing.
  """
  @behaviour AppworkTakeHome.Upstream
  alias AppworkTakeHome.{Request, Response}
  # This will still function as a constant due to Erlang's constant pools
  # See here for more info:
  # - https://github.com/discord/fastglobal
  # - https://www.erlang.org/docs/17/efficiency_guide/processes
  def delay_ms, do: 100

  def fetch(%Request{params: params}) do
    Process.sleep(delay_ms())
    %Response{data: params, ttl: 3600}
  end
end

defmodule AppworkTakeHome.CacheTest.SpyUpstream do
  @moduledoc """
  Instant upstream mock that notifies a designated listener process on every
  call.  Include `spy: pid` in the request params; the listener receives
  `{:upstream_called, params}` each time this upstream is invoked, enabling
  deterministic hit/miss detection without timing sensitivity.
  """
  @behaviour AppworkTakeHome.Upstream
  alias AppworkTakeHome.{Request, Response}

  def fetch(%Request{params: %{spy: pid} = params}) do
    send(pid, {:upstream_called, params})
    %Response{data: params, ttl: 3600}
  end
end

defmodule AppworkTakeHome.CacheTest.TTLSpyUpstream do
  @moduledoc """
  Instant upstream mock that returns responses with a TTL field.  The TTL
  value is taken from the request params (`ttl: seconds`), and the spy
  process (`spy: pid`) receives `{:upstream_called, params}` on every call.
  """
  @behaviour AppworkTakeHome.Upstream
  alias AppworkTakeHome.{Request, Response}

  def fetch(%Request{params: %{spy: pid, ttl: ttl} = params}) do
    send(pid, {:upstream_called, params})
    %Response{data: params, ttl: ttl}
  end
end
