defmodule McpClient.Application do
  @moduledoc """
  Lightweight application for STDIO client nodes.
  Connects to main broker and handles STDIO communication.
  """
  use Application
  require Logger

  def start(_type, _args) do
    # Disable all logging for STDIO transport compatibility
    Logger.configure(level: :emergency)

    # Generate unique node name
    node_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
    node_name = :"mcp_client_#{node_id}@localhost"

    # Debug output to stderr only
    IO.puts(:stderr, "Starting MCP client node: #{node_name}")

    # Start as distributed node
    case :net_kernel.start([node_name, :shortnames]) do
      {:ok, _} ->
        IO.puts(:stderr, "Started distributed node: #{node_name}")

      {:error, {:already_started, _}} ->
        IO.puts(:stderr, "Distributed node already started")

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start distributed node: #{inspect(reason)}")
        # Continue anyway in case we're already distributed
    end

    children = [
      McpClient.StdioHandler
    ]

    opts = [strategy: :one_for_one, name: McpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
