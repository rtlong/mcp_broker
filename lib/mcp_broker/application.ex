defmodule McpBroker.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Start as distributed node
    case :net_kernel.start([:"mcp_broker@localhost", :shortnames]) do
      {:ok, _} -> 
        Logger.info("Started distributed node: mcp_broker@localhost")
      
      {:error, {:already_started, _}} ->
        Logger.info("Distributed node already started")
      
      {:error, reason} ->
        Logger.error("Failed to start distributed node: #{inspect(reason)}")
    end

    config_path = System.get_env("MCP_CONFIG_PATH", "config.json")

    children =
      [
        # Add your supervised processes here
        Hermes.Server.Registry,
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
end
