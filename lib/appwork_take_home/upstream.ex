defmodule AppworkTakeHome.Upstream do
  @moduledoc """
  Behaviour for upstream services that the cache delegates to on a miss.
  """

  @callback fetch(AppworkTakeHome.Request.t()) :: AppworkTakeHome.Response.t()
end
