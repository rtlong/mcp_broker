defmodule McpBroker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
              transport: {:streamable_http, port: 4567},
              name: :mcp_broker_server
            ]
          }
        }
      ]

    opts = [strategy: :one_for_one, name: McpBroker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
