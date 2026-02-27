defmodule AppworkTakeHome.Cache do
  @moduledoc """
  A cache wraps an upstream service and stores responses for previously seen
  requests.

  Uses an ETS table for concurrent O(1) reads and a GenServer for serialised
  writes.  Both the ETS table reference and the upstream module are published
  via `:persistent_term` so that `fetch/2` can reach them without going
  through the GenServer on either the read or the upstream-call path.

  Eviction is LRU with optional TTL (V3). A cache hit moves the entry to the
  most-recently-used position, so only entries not accessed within the last CAP
  distinct requests are evicted.  Entries whose TTL has elapsed are treated as
  cache misses and re-fetched from the upstream.

  Two ETS tables maintain the LRU order:

    * `table` — the main store: `{key, counter, response, inserted_at}`.
      The counter is a monotonic integer that encodes the entry's last-access
      time.  `inserted_at` is a monotonic timestamp (milliseconds) used for
      TTL expiration checks.
    * `order_table` — an `:ordered_set` keyed by counter: `{counter, key}`.
      Because `:ordered_set` sorts ascending, `:ets.first/1` always returns
      the LRU entry's counter in O(log n) because ordered_set is implemented
      using a binary search tree.

  On a cache hit, the GenServer is called to update the entry's counter in
  both tables (touch), moving it to the MRU position.  On a cache miss the
  upstream is called concurrently (outside the GenServer), and only the
  subsequent write is serialised.
  """

  use GenServer

  alias AppworkTakeHome.{Request, Response}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the cache process.

  ## Options

    * `:cap` — maximum number of entries (required)
    * `:upstream` — module implementing `fetch/1` (required)
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
  GenServer entirely, so many can proceed in parallel.  Cache hits also
  update the LRU position via a lightweight GenServer call (bookkeeping only;
  the response is already in hand).
  """
  @spec fetch(cache :: pid() | atom(), request :: Request.t()) ::
          Response.t()
  def fetch(cache, %Request{} = request) do
    key = Request.cache_key(request)
    pid = resolve_pid(cache)
    %{table: table, upstream: upstream} = :persistent_term.get({__MODULE__, pid})

    case :ets.lookup(table, key) do
      [{^key, _counter, response, inserted_at}] ->
        if expired?(response, inserted_at) do
          response = upstream.fetch(request)
          GenServer.call(cache, {:put, key, response})
          response
        else
          GenServer.call(cache, {:touch, key})
          response
        end

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
    upstream = Keyword.fetch!(opts, :upstream)

    table = :ets.new(__MODULE__, [:public, {:read_concurrency, true}])
    order_table = :ets.new(:lru_order, [:ordered_set, :private])
    :persistent_term.put({__MODULE__, self()}, %{table: table, upstream: upstream})

    {:ok, %{table: table, order_table: order_table, cap: cap}}
  end

  @impl true
  def handle_call({:touch, key}, _from, %{table: table, order_table: order_table} = state) do
    case :ets.lookup(table, key) do
      [{^key, old_counter, _response, _inserted_at}] ->
        new_counter = :erlang.unique_integer([:monotonic])
        :ets.delete(order_table, old_counter)
        :ets.insert(order_table, {new_counter, key})
        :ets.update_element(table, key, [{2, new_counter}])

      [] ->
        # Entry was evicted between the ETS read in fetch/2 and this call.
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put, key, response}, _from, %{table: table, order_table: order_table} = state) do
    now = System.monotonic_time(:millisecond)

    state =
      if :ets.member(table, key) do
        case :ets.lookup(table, key) do
          [{^key, old_counter, _, _}] ->
            new_counter = :erlang.unique_integer([:monotonic])
            :ets.delete(order_table, old_counter)
            :ets.insert(order_table, {new_counter, key})
            :ets.update_element(table, key, [{2, new_counter}, {3, response}, {4, now}])

          [] ->
            :ok
        end

        state
      else
        counter = :erlang.unique_integer([:monotonic])
        :ets.insert(table, {key, counter, response, now})
        :ets.insert(order_table, {counter, key})
        maybe_evict(state)
      end

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{table: table, order_table: order_table}) do
    :persistent_term.erase({__MODULE__, self()})
    :ets.delete(table)
    :ets.delete(order_table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_evict(%{table: table, order_table: order_table, cap: cap} = state) do
    if :ets.info(table, :size) > cap do
      oldest_counter = :ets.first(order_table)
      [{^oldest_counter, lru_key}] = :ets.lookup(order_table, oldest_counter)
      :ets.delete(order_table, oldest_counter)
      :ets.delete(table, lru_key)
      state
    else
      state
    end
  end

  defp expired?(%Response{ttl: ttl}, inserted_at) do
    System.monotonic_time(:millisecond) - inserted_at >= ttl * 1_000
  end

  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
end
