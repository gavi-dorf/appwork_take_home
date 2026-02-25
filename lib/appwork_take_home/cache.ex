defmodule AppworkTakeHome.Cache do
  @moduledoc """
  A cache wraps an upstream service and stores responses for previously seen
  requests.

  Uses an ETS table for concurrent O(1) reads and a GenServer for serialised
  writes.  Both the ETS table reference and the upstream module are published
  via `:persistent_term` so that `fetch/2` can reach them without going
  through the GenServer on either the read or the upstream-call path.

  Eviction is FIFO (V1). The same entry is never stored twice — a cache hit
  does not update the entry's position in the eviction queue (that is V2 LRU
  behaviour).
  """

  use GenServer

  alias AppworkTakeHome.{Request, Response, SlowUpstream}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the cache process.

  ## Options

    * `:cap` — maximum number of entries (required)
    * `:upstream` — module implementing `fetch/1` (default: `SlowUpstream`)
    * `:name` — registered name for the process

  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    genserver_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Fetches the response for `request`, returning a cached response when
  available or delegating to the upstream service otherwise.

  Concurrent calls are safe: ETS reads and upstream calls both bypass the
  GenServer entirely, so many can proceed in parallel.
  """
  @spec fetch(cache :: GenServer.server(), request :: Request.t()) ::
          Response.t()
  def fetch(cache, %Request{} = request) do
    key = Request.cache_key(request)
    pid = resolve_pid(cache)
    %{table: table, upstream: upstream} = :persistent_term.get({__MODULE__, pid})

    case :ets.lookup(table, key) do
      [{^key, response}] ->
        response

      [] ->
        response = upstream.fetch(request)
        GenServer.call(cache, {:put, key, response})
        response
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cap = Keyword.fetch!(opts, :cap)
    upstream = Keyword.get(opts, :upstream, SlowUpstream)

    table = :ets.new(__MODULE__, [:public, {:read_concurrency, true}])
    :persistent_term.put({__MODULE__, self()}, %{table: table, upstream: upstream})

    {:ok, %{table: table, queue: :queue.new(), cap: cap}}
  end

  @impl true
  def handle_call({:put, key, response}, _from, %{table: table} = state) do
    state =
      if :ets.member(table, key) do
        # A concurrent caller already inserted this key; skip to avoid a
        # duplicate entry in the eviction queue.
        state
      else
        :ets.insert(table, {key, response})
        new_queue = :queue.in(key, state.queue)
        maybe_evict(%{state | queue: new_queue})
      end

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :persistent_term.erase({__MODULE__, self()})
    :ets.delete(table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_evict(%{table: table, queue: queue, cap: cap} = state) do
    if :ets.info(table, :size) > cap do
      {{:value, oldest_key}, rest} = :queue.out(queue)
      :ets.delete(table, oldest_key)
      %{state | queue: rest}
    else
      state
    end
  end

  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
end
