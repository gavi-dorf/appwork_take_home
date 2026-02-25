defmodule AppworkTakeHome.RequestTest do
  use ExUnit.Case

  alias AppworkTakeHome.Request

  test "cache_key returns an integer" do
    req = %Request{params: %{foo: "bar"}}
    assert is_integer(Request.cache_key(req))
  end

  test "identical params produce the same cache key" do
    req1 = %Request{params: %{foo: "bar"}}
    req2 = %Request{params: %{foo: "bar"}}
    assert Request.cache_key(req1) == Request.cache_key(req2)
  end

  test "different params produce different cache keys" do
    req1 = %Request{params: %{foo: "bar"}}
    req2 = %Request{params: %{foo: "baz"}}
    assert Request.cache_key(req1) != Request.cache_key(req2)
  end
end
