defmodule McpBrokerTest do
  use ExUnit.Case
  doctest McpBroker

  test "greets the world" do
    assert McpBroker.hello() == :world
  end
end
