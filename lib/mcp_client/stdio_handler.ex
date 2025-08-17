defmodule McpClient.StdioHandler do
  @moduledoc """
  Handles STDIO communication and proxies to distributed broker.
  """
  use GenServer
  require Logger

  @broker_node :"mcp_broker@localhost"
  
  # Get process info for logging
  defp log_prefix do
    node_name = Node.self() |> to_string() |> String.replace("mcp_client_", "")
    os_pid = System.pid()
    "[client:#{node_name}:#{os_pid}]"
  end
  
  # Custom Logger-style function that guarantees stderr output
  # This works around the known Elixir Logger stderr configuration issue
  defp stderr_log(level, message) do
    timestamp = DateTime.utc_now() 
                |> DateTime.to_string() 
                |> String.slice(0, 19)
                |> String.replace("T", " ")
    
    formatted = "#{timestamp} [#{level}] #{log_prefix()} #{message}"
    IO.puts(:stderr, formatted)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    stderr_log(:info, "Starting STDIO handler")
    
    # Connect to main broker
    case Node.connect(@broker_node) do
      true ->
        stderr_log(:info, "Connected to main broker: #{@broker_node}")
      
      false ->
        stderr_log(:error, "Failed to connect to main broker: #{@broker_node}")
        # Continue anyway - broker might not be ready yet
    end
    
    # Start reading from STDIN in a separate process
    spawn_link(fn -> read_stdin_loop() end)
    
    {:ok, state}
  end

  # Handle JSON-RPC messages from STDIN
  def handle_info({:stdin_message, message}, state) do
    case Jason.decode(message) do
      {:ok, request} ->
        handle_mcp_request(request)
      
      {:error, reason} ->
        stderr_log(:error, "Failed to parse JSON: #{inspect(reason)}")
        send_error_response(nil, -32700, "Parse error")
    end
    
    {:noreply, state}
  end

  def handle_info(msg, state) do
    stderr_log(:debug, "Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp handle_mcp_request(%{"method" => method, "params" => params, "id" => id}) do
    stderr_log(:info, "Handling MCP request: #{method}")
    
    # Check if broker is available with retry
    case wait_for_broker(5) do
      :timeout ->
        stderr_log(:error, "Broker not available after waiting")
        send_error_response(id, -32603, "Broker unavailable")
      
      _pid ->
        # Forward to distributed broker
        case GenServer.call({:global, :mcp_broker}, {:mcp_call, method, params, id}) do
          response when is_map(response) ->
            send_response(response)
          
          error ->
            stderr_log(:error, "Unexpected response from broker: #{inspect(error)}")
            send_error_response(id, -32603, "Internal error")
        end
    end
  catch
    :exit, {:noproc, _} ->
      stderr_log(:error, "Main broker not available")
      send_error_response(id, -32603, "Broker unavailable")
    
    kind, reason ->
      stderr_log(:error, "Error calling broker: #{kind} #{inspect(reason)}")
      send_error_response(id, -32603, "Internal error")
  end

  defp handle_mcp_request(%{"method" => method, "params" => _params}) do
    # Handle notification (no id) - notifications should not receive responses!
    stderr_log(:info, "Handling notification: #{method} (no response needed)")
    :ok
  end

  defp handle_mcp_request(%{"method" => method, "id" => id}) do
    # Handle request without params
    handle_mcp_request(%{"method" => method, "params" => %{}, "id" => id})
  end

  defp handle_mcp_request(invalid_request) do
    stderr_log(:error, "Invalid JSON-RPC request: #{inspect(invalid_request)}")
    # Only send error response if we have an id (not a notification)
    case Map.get(invalid_request, "id") do
      nil -> :ok  # Don't respond to notifications
      id -> send_error_response(id, -32600, "Invalid Request")
    end
  end

  defp send_response(response) do
    # Use escape: :unicode_safe to ensure proper JSON Unicode escaping (not \x{...} format)
    json = Jason.encode!(response, escape: :unicode_safe)
    
    # Dual log: send to stdout for MCP protocol and stderr for debugging
    IO.puts(:stdio, json)
    stderr_log(:debug, "Sending JSON response: #{json}")
  end

  defp send_error_response(id, code, message) do
    error_response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
    
    send_response(error_response)
  end

  defp read_stdin_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        stderr_log(:info, "STDIN closed, shutting down")
        System.stop(0)
      
      {:error, reason} ->
        stderr_log(:error, "Error reading STDIN: #{inspect(reason)}")
        System.stop(1)
      
      data when is_binary(data) ->
        trimmed = String.trim(data)
        
        if trimmed != "" do
          send(__MODULE__, {:stdin_message, trimmed})
        end
        
        read_stdin_loop()
    end
  end

  defp wait_for_broker(retries) when retries > 0 do
    # Debug distributed connection
    stderr_log(:debug, "Connected nodes: #{inspect(Node.list())}")
    stderr_log(:debug, "Global names: #{inspect(:global.registered_names())}")
    
    case :global.whereis_name(:mcp_broker) do
      :undefined ->
        stderr_log(:info, "Waiting for broker... (#{retries} retries left)")
        Process.sleep(1000)
        wait_for_broker(retries - 1)
      
      pid ->
        stderr_log(:info, "Found broker: #{inspect(pid)}")
        pid
    end
  end

  defp wait_for_broker(0) do
    :timeout
  end
end