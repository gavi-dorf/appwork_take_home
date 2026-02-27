# AppworkTakeHome

## Assumptions when interpreting instructions:
1. "Uses request structs as keys and response structs as values...Same as V1, with the added constraint that the stored entries are distinct request-response tuples." - At the implementation level, the hash is used as the ETS key, and the value is the response
2. "V1 - Basic Cache...It must store responses for at least the last CAP requests" - CAP is treated as maximum capacity and eviction occurs when capacity is exceeded
3. The requirements of V1 anyway imply distinctness ("If a request appears again within the last CAP requests, it should be served from cache and not forwarded upstream.") unless were to make a point of deliberately storing duplicate entries in cache, even after we have verified if they are already in the cache (which also would go against the general requirements that "...The cache must support high concurrency, allowing many concurrent fetch calls..." and "...Uses request structs as keys and response structs as values..."). Given this, then the only difference between V1 and V2 is that V1 is FIFO and V2 is LRU
4. "V2 - LRU Cache" - A cache hit moves the accessed entry to the most-recently-used position, so the entry "within the last CAP distinct requests" window is refreshed on access. This is implemented using two ETS tables: the main store adds a monotonic counter per entry, and a companion `:ordered_set` table sorted by that counter provides O(log n) LRU eviction and O(log n) touch. Cache hits now go through the GenServer (for the touch bookkeeping), but upstream calls and ETS reads remain concurrent - only the lightweight ordering update is serialised
5. "V3 - LRU + TTL Cache...TTL is a positive integer number of seconds." - It seems a bit unusual that the TTL would be stored as whole seconds rather than milliseconds, but to comply with the requirements it will be stored as whole seconds
6.
    "The cache must support high concurrency, allowing many concurrent `fetch/1` calls." - There is a potential issue with the implementation: Thundering Herd (See here for more info: https://en.wikipedia.org/wiki/Thundering_herd_problem and https://en.wikipedia.org/wiki/Cache_stampede). This is when many concurrent callers call fetch/1 at the same time when the cache entry has just expired, leading to each caller triggering the upstream service. (It's as if each "believes" that it is the first to make the call to the upstream.)

    To mitigate this would require either making the Cache GenServer even more of a bottleneck (by having one single GenServer/locking mechanism or a GenServer/locking mechanism for each key/request) and/or tracking in-flight requests and serving the stale response while requests are still busy processing.

    Since we don't know which of a) high concurrency, b) avoiding stale responses or c) not overloading the upstream is more important, it is justifiable for now to keep the implementation simpler and not yet add mitigation for Thundering Herd

## Architecture Diagrams

### Module Diagram

```mermaid
classDiagram
    class Cache {
        <<GenServer>>
        +start_link(opts) GenServer.on_start()
        +fetch(cache, request) Response.t()
        -init(opts)
        -handle_call(:touch, ...)
        -handle_call(:put, ...)
        -terminate(reason, state)
        -maybe_evict(state)
        -expired?(response, inserted_at)
        -resolve_pid(cache)
    }

    class Upstream {
        <<Behaviour>>
        +fetch(Request.t()) Response.t()
    }

    class Request {
        <<Struct>>
        +params : term()
        +cache_key(request) integer()
    }

    class Response {
        <<Struct>>
        +data : term()
        +ttl : pos_integer()
        +ttl(response) pos_integer()
    }

    class GenServerState {
        <<Map>>
        table : ets_ref
        order_table : ets_ref
        cap : pos_integer
    }

    class MainTable["ETS: Main Store (set)"] {
        key : integer
        counter : integer
        response : Response.t()
        inserted_at : integer
    }

    class OrderTable["ETS: LRU Order (ordered_set)"] {
        counter : integer
        key : integer
    }

    Cache --> Upstream : delegates misses to
    Cache --> Request : reads cache_key from
    Cache --> Response : stores and returns
    Cache --> GenServerState : internal state
    Cache --> MainTable : concurrent reads, serialised writes
    Cache --> OrderTable : LRU ordering (private)
    MainTable <..> OrderTable : counter links entries
```

### Data Flow

```mermaid
flowchart TD
    Caller["Caller Process"]
    Fetch["fetch(cache, request)"]
    Key["Request.cache_key(request)"]
    PT["persistent_term.get → {table, upstream}"]
    ETS["ETS lookup (lock-free)"]

    Hit{"HIT"}
    Miss{"MISS"}
    TTL{"TTL valid?"}

    UpstreamCall["upstream.fetch(request) (concurrent, outside GenServer)"]
    Touch["GenServer :touch (update LRU counter)"]
    Put["GenServer :put (insert + maybe evict LRU)"]

    Return["Return Response"]

    Caller --> Fetch --> Key --> PT --> ETS
    ETS --> Hit
    ETS --> Miss

    Hit --> TTL
    TTL -- "Yes" --> Touch --> Return
    TTL -- "No (expired)" --> UpstreamCall
    Miss --> UpstreamCall

    UpstreamCall --> Put --> Return
```

### Concurrency Design

```mermaid
flowchart LR
    subgraph Callers["Concurrent Caller Processes"]
        C1["Caller 1"]
        C2["Caller 2"]
        C3["Caller N"]
    end

    subgraph ReadPath["Lock-Free Read Path"]
        PT["persistent_term (zero-copy ETS ref + upstream)"]
        ETS["ETS Main Table (read_concurrency: true)"]
    end

    subgraph WritePath["Serialised Write Path"]
        GS["Cache GenServer"]
        OT["ETS Order Table (ordered_set, private)"]
    end

    subgraph External["External"]
        US["Upstream Service (implements Upstream behaviour)"]
    end

    C1 & C2 & C3 -- "1. resolve ETS ref" --> PT
    C1 & C2 & C3 -- "2. concurrent read" --> ETS
    C1 & C2 & C3 -. "3. miss/expired" .-> US
    US -. "4. response" .-> GS
    C1 & C2 & C3 -- "3. hit → touch" --> GS
    GS -- "update counters" --> ETS
    GS -- "maintain LRU order" --> OT
```

