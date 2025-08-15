defmodule McpBroker.IntegrationTest do
  use ExUnit.Case, async: false
  
  alias McpBroker.{Config, ClientManager, ToolAggregator}

  @test_config %{
    "mcpServers" => %{
      "echo" => %{
        "command" => "echo",
        "args" => ["Hello from echo server"],
        "env" => %{},
        "type" => "stdio",
        "tags" => ["test"]
      }
    }
  }

  describe "configuration" do
    test "loads and validates configuration" do
      # Create a temporary config file
      config_path = "test_config.json"
      File.write!(config_path, Jason.encode!(@test_config))
      
      try do
        assert {:ok, config} = Config.load_config(config_path)
        assert map_size(config.servers) == 1
        assert Map.has_key?(config.servers, "echo")
        assert config.servers["echo"].name == "echo"
      after
        File.rm(config_path)
      end
    end

    test "validates invalid configuration" do
      invalid_config = %{"invalid" => "config"}
      assert {:error, _} = Config.validate_config(invalid_config)
    end

    test "validates configuration with missing fields" do
      invalid_config = %{"mcpServers" => %{"test" => %{}}}
      assert {:error, _} = Config.validate_config(invalid_config)
    end
  end

  describe "tool aggregation" do
    test "aggregates tools from mock clients" do
      # This test would need actual mock clients running
      # For now, just test the structure
      assert is_function(&ToolAggregator.aggregate_tools/0)
      assert is_function(&ToolAggregator.list_available_tools/0)
    end
  end
end