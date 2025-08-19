defmodule McpBroker.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Start as distributed node with configurable name and host
    node_name = get_node_name()
    cookie = get_node_cookie()
    
    # Set cookie if provided
    if cookie do
      Node.set_cookie(String.to_atom(cookie))
    end
    
    case :net_kernel.start([node_name, :shortnames]) do
      {:ok, _} -> 
        Logger.info("Started distributed node: #{node_name}")
      
      {:error, {:already_started, _}} ->
        Logger.info("Distributed node already started")
      
      {:error, reason} ->
        Logger.error("Failed to start distributed node: #{inspect(reason)}")
        # In test environment, continue without distribution
        if Mix.env() == :test do
          Logger.warning("Continuing in test mode without distribution")
        else
          raise "Failed to start distributed node: #{inspect(reason)}"
        end
    end

    config_path = get_config_path()

    children =
      [
        # Add your supervised processes here
        Hermes.Server.Registry,
        McpBroker.ToolAggregator,
        {McpBroker.ClientManager, config_path},
        %{
          id: :mcp_broker_server,
          start: {
            Hermes.Server.Supervisor,
            :start_link,
            [
              McpBroker.Server,
              [
                transport: {:streamable_http, port: 4567},
                name: :mcp_broker_server
              ]
            ]
          }
        },
        McpBroker.DistributedServer
      ]

    opts = [strategy: :one_for_one, name: McpBroker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_node_name do
    base_name = System.get_env("MCP_BROKER_NODE_NAME", "mcp_broker")
    host = System.get_env("MCP_BROKER_NODE_HOST", "localhost")
    
    # Add unique suffix for test environment to prevent conflicts
    name_with_suffix = case Mix.env() do
      :test ->
        # Generate unique suffix for each test run
        suffix = :crypto.strong_rand_bytes(4) |> Base.encode16() |> String.downcase()
        "#{base_name}_test_#{suffix}"
      _ ->
        base_name
    end
    
    String.to_atom("#{name_with_suffix}@#{host}")
  end

  defp get_node_cookie do
    System.get_env("MCP_BROKER_NODE_COOKIE")
  end

  defp get_config_path do
    case Mix.env() do
      :test -> System.get_env("MCP_CONFIG_PATH", "test_config.json")
      _ -> System.get_env("MCP_CONFIG_PATH", "config.json")
    end
  end
end
