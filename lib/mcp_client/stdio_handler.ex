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
    
    # Load JWT token for authentication
    jwt_token = load_jwt_token()
    client_ref = generate_client_ref()
    
    # Connect to main broker
    case Node.connect(@broker_node) do
      true ->
        stderr_log(:info, "Connected to main broker: #{@broker_node}")
      
      false ->
        stderr_log(:error, "Failed to connect to main broker: #{@broker_node}")
        # Continue anyway - broker might not be ready yet
    end
    
    # Initialize state with authentication info
    new_state = Map.merge(state, %{
      jwt_token: jwt_token,
      client_ref: client_ref,
      authenticated: false
    })
    
    # Start reading from STDIN in a separate process
    spawn_link(fn -> read_stdin_loop() end)
    
    {:ok, new_state}
  end

  # Handle JSON-RPC messages from STDIN
  def handle_info({:stdin_message, message}, state) do
    case Jason.decode(message) do
      {:ok, request} ->
        handle_mcp_request(request, state)
      
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

  defp handle_mcp_request(%{"method" => method, "params" => params, "id" => id}, state) do
    stderr_log(:info, "Handling MCP request: #{method}")
    
    # Check if broker is available with retry
    case wait_for_broker(5) do
      :timeout ->
        stderr_log(:error, "Broker not available after waiting")
        send_error_response(id, -32603, "Broker unavailable")
      
      _pid ->
        # Authenticate if not already authenticated
        authenticated_state = ensure_authenticated(state)
        
        # Forward to distributed broker with client reference
        case GenServer.call({:global, :mcp_broker}, {:mcp_call, method, params, id, authenticated_state.client_ref}) do
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

  defp handle_mcp_request(%{"method" => method, "params" => _params}, _state) do
    # Handle notification (no id) - notifications should not receive responses!
    stderr_log(:info, "Handling notification: #{method} (no response needed)")
    :ok
  end

  defp handle_mcp_request(%{"method" => method, "id" => id}, state) do
    # Handle request without params
    handle_mcp_request(%{"method" => method, "params" => %{}, "id" => id}, state)
  end

  defp handle_mcp_request(invalid_request, _state) do
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

  # Authentication helper functions

  defp load_jwt_token do
    # Try environment variable first
    case System.get_env("MCP_CLIENT_JWT") do
      nil ->
        # Try config file
        case load_jwt_from_config() do
          {:ok, token} -> token
          {:error, reason} ->
            stderr_log(:warning, "No JWT token found: #{reason}. Running in development mode.")
            nil
        end
      token when is_binary(token) ->
        stderr_log(:info, "Loaded JWT token from MCP_CLIENT_JWT environment variable")
        token
    end
  end

  defp load_jwt_from_config do
    config_path = Path.expand("~/.mcp/client.json")
    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"jwt" => token}} when is_binary(token) ->
            stderr_log(:info, "Loaded JWT token from config file: #{config_path}")
            {:ok, token}
          {:ok, _} ->
            {:error, "Config file missing 'jwt' field"}
          {:error, reason} ->
            {:error, "Invalid JSON in config file: #{reason}"}
        end
      {:error, :enoent} ->
        {:error, "Config file not found at #{config_path}"}
      {:error, reason} ->
        {:error, "Cannot read config file: #{reason}"}
    end
  end

  defp generate_client_ref do
    # Generate a unique reference for this client session
    node_name = Node.self() |> to_string()
    timestamp = :os.system_time(:millisecond)
    "#{node_name}_#{timestamp}"
  end

  defp ensure_authenticated(state) do
    if state.authenticated do
      state
    else
      case authenticate_with_broker(state) do
        {:ok, new_state} -> new_state
        {:error, reason} ->
          stderr_log(:error, "Authentication failed: #{reason}")
          # Return original state, calls will fail with permission errors
          state
      end
    end
  end

  defp authenticate_with_broker(%{jwt_token: nil} = state) do
    stderr_log(:warning, "No JWT token available - running in development mode without authentication")
    # Mark as authenticated for development mode
    {:ok, %{state | authenticated: true}}
  end

  defp authenticate_with_broker(%{jwt_token: token, client_ref: client_ref} = state) do
    case GenServer.call({:global, :mcp_broker}, {:authenticate, token, client_ref}) do
      {:ok, _client_context} ->
        stderr_log(:info, "Successfully authenticated with broker")
        {:ok, %{state | authenticated: true}}
      
      {:error, reason} ->
        stderr_log(:error, "Authentication failed: #{inspect(reason)}")
        {:error, reason}
    end
  catch
    kind, reason ->
      stderr_log(:error, "Error during authentication: #{kind} #{inspect(reason)}")
      {:error, "Authentication call failed"}
  end
end