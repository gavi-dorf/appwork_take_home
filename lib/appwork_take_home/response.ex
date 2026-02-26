defmodule AppworkTakeHome.Response do
  @moduledoc """
  A response struct returned by the upstream service and stored in the cache.
  """

  @enforce_keys [:data]
  defstruct [:data, :ttl]

  @type t() :: %__MODULE__{data: term(), ttl: pos_integer() | nil}

  @doc "Returns the TTL (in seconds) for this response, or `nil` if unset."
  @spec ttl(%__MODULE__{}) :: pos_integer() | nil
  def ttl(%__MODULE__{ttl: ttl}), do: ttl
end
