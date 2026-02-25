defmodule AppworkTakeHome.Response do
  @moduledoc """
  A response struct returned by the upstream service and stored in the cache.
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t() :: %__MODULE__{data: term()}
end
