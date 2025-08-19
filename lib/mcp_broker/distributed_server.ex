defmodule McpBroker.DistributedServer do
  @moduledoc """
  Main broker node that manages MCP server connections and serves
  tools to distributed client nodes.
  
  This server registers globally and handles calls from lightweight
  client nodes via Erlang distribution.
  """
  use GenServer

  require Logger

  @doc """
  Starts the distributed server and registers it globally.
  """
  def start_link(opts \\ []) do
    Logger.info("Attempting to start distributed server with global name :mcp_broker")
    case GenServer.start_link(__MODULE__, opts, name: {:global, :mcp_broker}) do
      {:ok, pid} ->
        Logger.info("Successfully started distributed server with PID #{inspect(pid)}")
        Logger.info("Global registration check: #{inspect(:global.whereis_name(:mcp_broker))}")
        {:ok, pid}
      
      error ->
        Logger.error("Failed to start distributed server: #{inspect(error)}")
        error
    end
  end

  @doc """
  Authenticates a client with a JWT token.
  """
  def authenticate_client(jwt_token, client_ref) do
    GenServer.call({:global, :mcp_broker}, {:authenticate, jwt_token, client_ref})
  end

  @doc """
  Handles MCP calls from distributed client nodes.
  """
  def handle_mcp_call(method, params, id \\ nil, client_ref \\ nil) do
    GenServer.call({:global, :mcp_broker}, {:mcp_call, method, params, id, client_ref})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting distributed MCP broker server")
    
    # Wait for the main MCP server to be ready
    wait_for_mcp_server()
    
    # Trigger tool registration manually since no HTTP client will connect
    trigger_tool_registration()
    
    # Verify global registration
    case :global.whereis_name(:mcp_broker) do
      :undefined ->
        Logger.error("CRITICAL: Distributed server not registered globally after init!")
      
      pid ->
        Logger.info("Distributed server successfully registered globally as #{inspect(pid)}")
    end
    
    # State includes authenticated clients map
    {:ok, %{authenticated_clients: %{}}}
  end

  @impl true
  def handle_call({:authenticate, jwt_token, client_ref}, _from, state) do
    case McpBroker.Auth.JWT.verify_token(jwt_token) do
      {:ok, claims} ->
        client_context = McpBroker.Auth.ClientContext.from_jwt_claims(claims)
        new_state = put_in(state.authenticated_clients[client_ref], client_context)
        
        Logger.info("Client authenticated: #{McpBroker.Auth.ClientContext.to_log_string(client_context)}")
        
        {:reply, {:ok, client_context}, new_state}
      
      {:error, reason} ->
        Logger.warning("Authentication failed for client #{client_ref}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mcp_call, method, params, id, client_ref}, _from, state) do
    Logger.debug("Handling MCP call: #{method} from client #{client_ref}")
    
    client_context = get_in(state.authenticated_clients[client_ref])
    
    # Handle different MCP methods
    response = case method do
      "tools/list" ->
        handle_tools_list(id, client_context)
      
      "tools/call" ->
        handle_tool_call(params, id, client_context)
      
      "initialize" ->
        handle_initialize(params, id)
      
      _ ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32601,
            "message" => "Method not found",
            "data" => %{"method" => method}
          }
        }
    end
    
    {:reply, response, state}
  end

  # Legacy handler for backwards compatibility
  @impl true
  def handle_call({:mcp_call, method, params, id}, from, state) do
    handle_call({:mcp_call, method, params, id, nil}, from, state)
  end

  @impl true
  def handle_call({:ping}, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp handle_initialize(params, id) do
    Logger.info("Client initializing: #{inspect(params)}")
    
    %{
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
  end

  defp handle_tools_list(id, client_context) do
    case get_tools(client_context) do
      {:ok, tools} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => Enum.map(tools, fn tool ->
              %{
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => tool.input_schema
              }
            end)
          }
        }
      
      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32603,
            "message" => "Failed to list tools",
            "data" => reason
          }
        }
    end
  end

  defp handle_tool_call(params, id, client_context) do
    case validate_tool_call_params(params) do
      {:ok, {tool_name, arguments}} ->
        execute_tool_call(tool_name, arguments, id, client_context)
      
      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32602,
            "message" => "Invalid params",
            "data" => McpBroker.Errors.format_error(reason)
          }
        }
    end
  end

  defp execute_tool_call(tool_name, arguments, id, client_context) do
    # Check if client has access to this tool
    if client_context && not tool_accessible_to_client?(tool_name, client_context) do
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => -32603,
          "message" => "Access denied",
          "data" => %{"tool" => tool_name, "reason" => "Client does not have access to this tool"}
        }
      }
    else
      case McpBroker.ToolAggregator.call_tool(tool_name, arguments) do
        {:ok, result} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "content" => [
                %{
                  "type" => "text",
                  "text" => format_result(result)
                }
              ]
            }
          }
        
        {:error, reason} ->
          structured_error = {:tool_execution_failed, tool_name, reason}
          Logger.error("Tool call failed for '#{tool_name}': #{McpBroker.Errors.format_error(structured_error)}")
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{
              "code" => -32603,
              "message" => "Tool execution failed",
              "data" => %{"tool" => tool_name, "reason" => McpBroker.Errors.format_error(structured_error)}
            }
          }
      end
    end
  end

  defp get_tools(client_context) do
    case :ets.whereis(:mcp_broker_tools_registered) do
      :undefined ->
        {:error, "Tools not yet registered"}
      
      _table ->
        case :ets.lookup(:mcp_broker_tools_registered, :tools) do
          [{:tools, tools}] ->
            filtered_tools = if client_context do
              filter_tools_by_client_access(tools, client_context)
            else
              tools
            end
            {:ok, filtered_tools}
          
          [] ->
            {:error, "No tools available"}
        end
    end
  end

  defp filter_tools_by_client_access(tools, client_context) do
    Enum.filter(tools, fn tool ->
      tool_accessible_to_client?(tool.name, client_context)
    end)
  end

  defp tool_accessible_to_client?(tool_name, client_context) do
    # Get server tags for this tool
    case McpBroker.ToolAggregator.get_tool_server_tags(tool_name) do
      {:ok, server_tags} ->
        McpBroker.Auth.ClientContext.has_access_to_tags?(client_context, server_tags)
      
      {:error, _} ->
        # If we can't determine server tags, deny access for safety
        false
    end
  end

  defp validate_tool_call_params(params) when is_map(params) do
    with {:ok, tool_name} <- validate_tool_name(Map.get(params, "name")),
         {:ok, arguments} <- validate_tool_arguments(Map.get(params, "arguments", %{})) do
      {:ok, {tool_name, arguments}}
    end
  end
  defp validate_tool_call_params(_), do: {:error, {:invalid_tool_params, "params must be a map"}}

  defp validate_tool_name(name) when is_binary(name) and byte_size(name) > 0 do
    # Tool name should be alphanumeric with underscores, hyphens, dots
    if Regex.match?(~r/^[a-zA-Z0-9._-]+$/, name) do
      {:ok, name}
    else
      {:error, {:invalid_tool_params, "tool name contains invalid characters"}}
    end
  end
  defp validate_tool_name(nil), do: {:error, {:invalid_tool_params, "tool name is required"}}
  defp validate_tool_name(_), do: {:error, {:invalid_tool_params, "tool name must be a string"}}

  defp validate_tool_arguments(args) when is_map(args) do
    # Basic validation - ensure it's a map and check size limit
    if map_size(args) <= 100 do
      {:ok, args}
    else
      {:error, {:invalid_tool_params, "too many arguments (max 100)"}}
    end
  end
  defp validate_tool_arguments(_), do: {:error, {:invalid_tool_params, "arguments must be a map"}}

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: Jason.encode!(result, pretty: true)

  defp trigger_tool_registration do
    Logger.info("Triggering tool registration for distributed clients")
    
    case McpBroker.ToolAggregator.aggregate_tools() do
      {:ok, tools} ->
        Logger.info("Registered #{length(tools)} tools: #{Enum.map(tools, & &1.name) |> Enum.join(", ")}")
        
        # Store tools in ETS for distributed access
        case :ets.whereis(:mcp_broker_tools_registered) do
          :undefined ->
            :ets.new(:mcp_broker_tools_registered, [:set, :protected, :named_table])
          
          _table ->
            :ok
        end
        
        :ets.insert(:mcp_broker_tools_registered, {:tools, tools})
        :ok
      
      {:error, reason} ->
        Logger.error("Failed to register tools: #{inspect(reason)}")
        :error
    end
  end

  defp wait_for_mcp_server(retries \\ 50) do
    case GenServer.whereis(:mcp_broker_server) do
      nil when retries > 0 ->
        Process.sleep(100)
        wait_for_mcp_server(retries - 1)
      
      nil ->
        Logger.error("MCP server not available after waiting")
        :error
      
      _pid ->
        Logger.info("MCP server is ready")
        :ok
    end
  end
end