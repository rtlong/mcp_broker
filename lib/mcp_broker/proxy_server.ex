defmodule McpBroker.ProxyServer do
  @moduledoc """
  TCP server that accepts connections from stdio proxy clients.
  
  This allows the main service to run as a daemon with HTTP transport,
  while stdio clients can connect via TCP socket for TLS-free access.
  """
  
  use GenServer
  require Logger
  
  @default_port 9898
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    
    case :gen_tcp.listen(port, [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      backlog: 1024
    ]) do
      {:ok, listen_socket} ->
        Logger.info("MCP Proxy Server listening on port #{port}")
        # Start accepting connections
        spawn_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{listen_socket: listen_socket, port: port}}
      {:error, reason} ->
        Logger.error("Failed to start proxy server: #{inspect(reason)}")
        {:stop, reason}
    end
  end
  
  @impl true
  def terminate(_reason, %{listen_socket: socket}) do
    :gen_tcp.close(socket)
  end
  
  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn a process to handle this client
        spawn_link(fn -> handle_client(client_socket) end)
        accept_loop(listen_socket)
      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
    end
  end
  
  defp handle_client(socket) do
    Logger.info("New stdio proxy client connected")
    
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        # Forward the MCP message to our local MCP server
        response = forward_to_mcp_server(String.trim(data))
        :gen_tcp.send(socket, response <> "\n")
        handle_client(socket)
      {:error, :closed} ->
        Logger.info("Stdio proxy client disconnected")
        :gen_tcp.close(socket)
      {:error, reason} ->
        Logger.error("Socket error: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end
  end
  
  defp forward_to_mcp_server(message) do
    # Parse JSON and handle MCP protocol
    try do
      request = Jason.decode!(message)
      
      case handle_mcp_request(request) do
        {:ok, response} -> Jason.encode!(response)
        {:error, error} -> Jason.encode!(error)
      end
    rescue
      e ->
        error_response = %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{
            "code" => -32700,
            "message" => "Parse error",
            "data" => inspect(e)
          }
        }
        Jason.encode!(error_response)
    end
  end
  
  defp handle_mcp_request(%{"method" => "initialize", "id" => id} = _request) do
    # Return our server capabilities
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "McpBroker",
          "version" => "0.1.0"
        }
      }
    }
    {:ok, response}
  end
  
  defp handle_mcp_request(%{"method" => "tools/list", "id" => id}) do
    # Get tools from our aggregator
    case McpBroker.ToolAggregator.list_available_tools() do
      {:ok, tools} ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"tools" => tools}
        }
        {:ok, response}
      {:error, reason} ->
        error = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32603,
            "message" => "Internal error",
            "data" => inspect(reason)
          }
        }
        {:error, error}
    end
  end
  
  defp handle_mcp_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => tool_name, "arguments" => arguments}}) do
    case McpBroker.ToolAggregator.call_tool(tool_name, arguments) do
      {:ok, result} ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => format_result(result)}]
          }
        }
        {:ok, response}
      {:error, reason} ->
        error = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32603,
            "message" => "Tool execution failed",
            "data" => inspect(reason)
          }
        }
        {:error, error}
    end
  end
  
  defp handle_mcp_request(%{"method" => method, "id" => id}) do
    # Unknown method
    error = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not found",
        "data" => method
      }
    }
    {:error, error}
  end
  
  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: Jason.encode!(result, pretty: true)
end