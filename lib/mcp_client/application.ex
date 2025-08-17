defmodule McpClient.Application do
  @moduledoc """
  Lightweight application for STDIO client nodes.
  Connects to main broker and handles STDIO communication.
  """
  use Application
  def start(_type, _args) do
    # Generate unique node name
    node_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
    node_name = :"mcp_client_#{node_id}@localhost"
    os_pid = System.pid()

    # Custom Logger-style function that guarantees stderr output
    stderr_log = fn level, message ->
      timestamp = DateTime.utc_now() 
                  |> DateTime.to_string() 
                  |> String.slice(0, 19)
                  |> String.replace("T", " ")
      
      formatted = "#{timestamp} [#{level}] [client:#{node_id}:#{os_pid}] #{message}"
      IO.puts(:stderr, formatted)
    end

    stderr_log.(:info, "Starting MCP client node: #{node_name}")

    # Start as distributed node
    case :net_kernel.start([node_name, :shortnames]) do
      {:ok, _} ->
        stderr_log.(:info, "Started distributed node: #{node_name}")

      {:error, {:already_started, _}} ->
        stderr_log.(:info, "Distributed node already started")

      {:error, reason} ->
        stderr_log.(:error, "Failed to start distributed node: #{inspect(reason)}")
        # Continue anyway in case we're already distributed
    end

    children = [
      McpClient.StdioHandler
    ]

    opts = [strategy: :one_for_one, name: McpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
