# AppworkTakeHome

## Assumptions when interpreting instructions:
1. "Uses request structs as keys and response structs as values...Same as V1, with the added constraint that the stored entries are distinct request-response tuples." - At the implementation level, the hash is used as the ETS key, and the value is the response
2. "V1 - Basic Cache...It must store responses for at least the last CAP requests" - CAP is treated as maximum capacity and eviction occurs when capacity is exceeded

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

