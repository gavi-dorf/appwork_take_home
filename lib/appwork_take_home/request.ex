defmodule AppworkTakeHome.Request do
  @moduledoc """
  A request struct representing a call to the upstream service.

  Two requests with identical `params` are considered equivalent and will
  produce the same cache key.
  """

  @enforce_keys [:params]
  defstruct [:params]

  @type t() :: %__MODULE__{params: term()}

  @doc "Returns a nearly-unique integer hash for use as a cache key."
  @spec cache_key(%__MODULE__{}) :: integer()
  def cache_key(%__MODULE__{params: params}), do: :erlang.phash2(params)
end
