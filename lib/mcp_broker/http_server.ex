defmodule McpBroker.HttpServer do
  @moduledoc """
  HTTP server that serves the MCP broker via streamable_http transport.

  This module sets up a Cowboy HTTP server and routes /mcp requests
  to the Hermes MCP transport.
  """

  use Plug.Router
  require Logger

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  # Forward MCP requests to Hermes transport
  forward("/mcp",
    to: Hermes.Server.Transport.StreamableHTTP.Plug,
    init_opts: [server: McpBroker.Server]
  )

  # Health check endpoint
  get "/health" do
    send_resp(conn, 200, "OK")
  end

  # Catch-all for other requests
  match _ do
    send_resp(conn, 404, "Not Found")
  end

  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4567)

    Logger.info("Starting HTTP server on port #{port}")

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: __MODULE__,
      options: [port: port]
    )
  end
end
