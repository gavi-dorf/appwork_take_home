defmodule AppworkTakeHome.Response do
  @moduledoc """
  A response struct returned by the upstream service and stored in the cache.
  """

  @enforce_keys [:data, :ttl]
  defstruct [:data, :ttl]

  @type t() :: %__MODULE__{data: term(), ttl: pos_integer()}

  @doc "Returns the TTL (in seconds) for this response"
  @spec ttl(%__MODULE__{}) :: pos_integer()
  def ttl(%__MODULE__{ttl: ttl}), do: ttl
end
