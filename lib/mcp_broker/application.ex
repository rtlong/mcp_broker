defmodule McpBroker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config_path = System.get_env("MCP_CONFIG_PATH", "config.json")
    transport = parse_transport(System.get_env("MCP_TRANSPORT", "streamable_http"))

    children = [
      # Add your supervised processes here
      Hermes.Server.Registry,
      {McpBroker.ClientManager, config_path},
      %{
        id: :mcp_broker_server,
        start:
          {Hermes.Server.Supervisor, :start_link,
           [McpBroker.Server, [transport: transport, name: :mcp_broker_server]]}
      },
      {McpBroker.ProxyServer, []}
    ] ++ http_server_children(transport)

    opts = [strategy: :one_for_one, name: McpBroker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_server_children({:streamable_http, opts}) do
    port = Keyword.get(opts, :port, 4567)
    [{McpBroker.HttpServer, [port: port]}]
  end
  
  defp http_server_children(_transport) do
    []
  end

  defp parse_transport("stdio"), do: :stdio
  defp parse_transport("streamable_http"), do: {:streamable_http, [port: 4567]}
  defp parse_transport("sse"), do: {:sse, port: 4567, start: true}
  defp parse_transport("websocket"), do: :websocket
  defp parse_transport(_), do: {:streamable_http, [port: 4567]}
end
