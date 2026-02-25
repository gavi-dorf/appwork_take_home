defmodule AppworkTakeHome.SlowUpstreamTest do
  use ExUnit.Case

  alias AppworkTakeHome.{Request, Response, SlowUpstream}

  test "fetch returns a Response struct" do
    req = %Request{params: %{a: 1}}
    assert %Response{} = SlowUpstream.fetch(req)
  end

  test "same request yields the same response" do
    req = %Request{params: %{a: 1}}
    assert SlowUpstream.fetch(req) == SlowUpstream.fetch(req)
  end

  test "different requests yield different responses" do
    req1 = %Request{params: %{a: 1}}
    req2 = %Request{params: %{b: 2}}
    assert SlowUpstream.fetch(req1) != SlowUpstream.fetch(req2)
  end
end
