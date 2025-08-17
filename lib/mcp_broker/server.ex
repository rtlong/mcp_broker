defmodule McpBroker.Server do
  use Hermes.Server,
    name: "McpBroker",
    version: McpBroker.MixProject.project()[:version],
    protocol_version: "2024-11-05",
    capabilities: [:tools]

  alias McpBroker.ToolAggregator
  alias Hermes.Server.{Response, Frame}
  alias Hermes.MCP.Error
  require Logger

  @impl true
  def init(_client_info, frame) do
    Logger.info("McpBroker Server initialized for new client")
    # Check if tools are already registered globally
    case :ets.whereis(:mcp_broker_tools_registered) do
      :undefined ->
        # First client - start the tool registration process
        Logger.info(
          "First client connecting - creating ETS table and scheduling tool registration"
        )

        :ets.new(:mcp_broker_tools_registered, [:set, :public, :named_table])
        # Wait for clients to be ready
        Process.send_after(self(), :register_tools, 3000)
        {:ok, frame}

      _table ->
        # Tools already registered, get them from the table
        case :ets.lookup(:mcp_broker_tools_registered, :tools) do
          [{:tools, tools}] ->
            Logger.info(
              "Subsequent client connecting - loading #{length(tools)} tools from cache"
            )

            frame =
              Enum.reduce(tools, frame, fn tool, acc ->
                Frame.register_tool(acc, tool.name,
                  description: tool.description,
                  input_schema: tool.input_schema
                )
              end)

            {:ok, frame}

          [] ->
            # Table exists but no tools yet, wait
            Logger.info("ETS table exists but no tools cached yet - waiting for registration")
            Process.send_after(self(), :register_tools, 1000)
            {:ok, frame}
        end
    end
  end

  @impl true
  def handle_info(:register_tools, frame) do
    frame = register_dynamic_tools(frame)
    {:noreply, frame}
  end

  @impl true
  def handle_tool_call(tool_name, arguments, frame) do
    case ToolAggregator.call_tool(tool_name, arguments) do
      {:ok, result} ->
        {:reply,
         Response.json(
           Response.tool(),
           [%{"type" => "text", "text" => format_result(result)}]
         ), frame}

      {:error, reason} ->
        Logger.error("Tool call failed for '#{tool_name}': #{inspect(reason)}")
        {:reply, Response.error(Response.tool(), "Query failed: #{to_string(reason)}"), frame}

        # {:error, reason} ->
        #   error =
        #     Error.execution("Tool execution failed", %{tool: tool_name, reason: inspect(reason)})

        #   {:error, error, frame}
    end
  end

  defp register_dynamic_tools(frame) do
    case ToolAggregator.aggregate_tools() do
      {:ok, tools} ->
        Logger.info(
          "Registering #{length(tools)} dynamic tools: #{Enum.map(tools, & &1.name) |> Enum.join(", ")}"
        )

        # Store tools in ETS for future client sessions
        case :ets.whereis(:mcp_broker_tools_registered) do
          :undefined ->
            :ets.new(:mcp_broker_tools_registered, [:set, :public, :named_table])

          _table ->
            :ok
        end

        :ets.insert(:mcp_broker_tools_registered, {:tools, tools})

        # Register tools in this frame
        Enum.reduce(tools, frame, fn tool, acc ->
          Frame.register_tool(acc, tool.name,
            description: tool.description,
            input_schema: tool.input_schema
          )
        end)

      {:error, reason} ->
        Logger.error("Failed to register dynamic tools: #{inspect(reason)}")
        frame
    end
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: Jason.encode!(result, pretty: true)
end
