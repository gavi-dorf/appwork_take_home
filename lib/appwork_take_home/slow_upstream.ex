defmodule AppworkTakeHome.SlowUpstream do
  @moduledoc """
  A simulated upstream service with artificial latency.

  Returns a deterministic `AppworkTakeHome.Response` for each request —
  the same params always produce the same response data.
  """

  def fetch(%AppworkTakeHome.Request{params: params}) do
    # Simulate doing work by sleeping for 100ms. In a real implementation, this would be where you make an HTTP request or perform some expensive computation.
    Process.sleep(100)

    # Use the hash function again just as a way of generating data that is deterministic based on the input params. In a real implementation, this would be the actual data returned from the upstream service.
    %AppworkTakeHome.Response{data: :erlang.phash2(params)}
  end
end
