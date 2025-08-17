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
  Handles MCP calls from distributed client nodes.
  """
  def handle_mcp_call(method, params, id \\ nil) do
    GenServer.call({:global, :mcp_broker}, {:mcp_call, method, params, id})
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
    
    {:ok, %{}}
  end

  @impl true
  def handle_call({:mcp_call, method, params, id}, _from, state) do
    Logger.debug("Handling MCP call: #{method}")
    
    # Handle different MCP methods
    response = case method do
      "tools/list" ->
        handle_tools_list(id)
      
      "tools/call" ->
        handle_tool_call(params, id)
      
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

  defp handle_tools_list(id) do
    case get_tools() do
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

  defp handle_tool_call(params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    
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
        Logger.error("Tool call failed for '#{tool_name}': #{inspect(reason)}")
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32603,
            "message" => "Tool execution failed",
            "data" => %{"tool" => tool_name, "reason" => to_string(reason)}
          }
        }
    end
  end

  defp get_tools do
    case :ets.whereis(:mcp_broker_tools_registered) do
      :undefined ->
        {:error, "Tools not yet registered"}
      
      _table ->
        case :ets.lookup(:mcp_broker_tools_registered, :tools) do
          [{:tools, tools}] ->
            {:ok, tools}
          
          [] ->
            {:error, "No tools available"}
        end
    end
  end

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
            :ets.new(:mcp_broker_tools_registered, [:set, :public, :named_table])
          
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