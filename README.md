# AppworkTakeHome

## Assumptions when interpreting instructions:
1. "Uses request structs as keys and response structs as values...Same as V1, with the added constraint that the stored entries are distinct request-response tuples." - At the implementation level, the hash is used as the ETS key, and the value is the response
2. "V1 - Basic Cache...It must store responses for at least the last CAP requests" - CAP is treated as maximum capacity and eviction occurs when capacity is exceeded
3. The requirements of V1 anyway imply distinctness ("If a request appears again within the last CAP requests, it should be served from cache
and not forwarded upstream.") unless were to make a point of deliberately storing duplicate entries in cache, even after we have verified if they are already in the cache (which also would go against the general requirements that "...The cache must support high concurrency, allowing many concurrent fetch calls..." and "...Uses request structs as keys and response structs as values..."). Given this, then the only difference between V1 and V2 is that V1 is FIFO and V2 is LRU
4. "V2 - LRU Cache" - a cache hit moves the accessed entry to the most-recently-used position, so the entry "within the last CAP distinct requests" window is refreshed on access. This is implemented using two ETS tables: the main store adds a monotonic counter per entry, and a companion `:ordered_set` table sorted by that counter provides O(log n) LRU eviction and O(log n) touch. Cache hits now go through the GenServer (for the touch bookkeeping), but upstream calls and ETS reads remain concurrent — only the lightweight ordering update is serialised.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `appwork_take_home` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:appwork_take_home, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/appwork_take_home>.

