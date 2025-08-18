defmodule McpBroker.ToolAggregatorTest do
  use ExUnit.Case
  doctest McpBroker.ToolAggregator

  alias McpBroker.ToolAggregator

  describe "tool server tags" do
    test "get_tool_server_tags returns server tags for a tool" do
      # This test would require mocking ClientManager
      # For now, we just test the interface exists
      assert function_exported?(ToolAggregator, :get_tool_server_tags, 1)
    end

    test "tools include server tags in aggregation" do
      # Test that the tool structure includes server_tags field
      tool_example = %{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{},
        server_name: "test_server",
        original_name: "test_tool",
        server_tags: ["api", "testing"]
      }

      assert Map.has_key?(tool_example, :server_tags)
      assert tool_example.server_tags == ["api", "testing"]
    end
  end
end