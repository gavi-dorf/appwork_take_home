defmodule AppworkTakeHome.Cache do
  @moduledoc """
  A cache wraps an upstream service and stores responses for previously seen
  requests.
  """

  @doc """
  Starts the cache process.

  ## Options

    * `:cap` — maximum number of entries (required)
    * `:name` — registered name for the process

  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
  end

  @doc """
  Fetches the response for `request`, returning a cached response when available
  or delegating to the upstream service otherwise.
  """
  @spec fetch(cache :: GenServer.server(), request :: AppworkTakeHome.Request) ::
          AppworkTakeHome.Response
  def fetch(cache, %AppworkTakeHome.Request{} = request) do
  end
end
