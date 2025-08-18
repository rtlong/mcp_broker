defmodule McpBroker.ToolAggregator do
  @moduledoc """
  Aggregates tools from multiple MCP clients and handles name conflicts.
  """

  alias McpBroker.ClientManager

  @type tool_with_source :: %{
    name: String.t(),
    description: String.t(),
    input_schema: map(),
    server_name: String.t(),
    original_name: String.t(),
    server_tags: [String.t()]
  }

  @spec aggregate_tools() :: {:ok, [tool_with_source()]} | {:error, term()}
  def aggregate_tools do
    with {:ok, server_tools} <- ClientManager.list_all_tools(),
         {:ok, client_info} <- ClientManager.get_client_info() do
      tools = 
        server_tools
        |> Enum.flat_map(fn {server_name, tools} ->
          server_tags = get_in(client_info, [server_name, :tags]) || []
          tools
          |> Enum.map(&add_server_info(&1, server_name, server_tags))
        end)
        |> resolve_name_conflicts()

      {:ok, tools}
    end
  end

  @spec call_tool(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(tool_name, arguments) do
    with {:ok, tools} <- aggregate_tools(),
         {:ok, tool} <- find_tool(tools, tool_name) do
      ClientManager.call_tool(tool.server_name, tool.original_name, arguments)
    end
  end

  defp add_server_info(tool, server_name, server_tags) do
    %{
      name: tool["name"],
      description: tool["description"],
      input_schema: simplify_schema(tool["inputSchema"] || tool["input_schema"] || %{}),
      server_name: server_name,
      original_name: tool["name"],
      server_tags: server_tags
    }
  end

  # Simplify complex JSON Schema to basic Peri-compatible format
  defp simplify_schema(schema) when is_map(schema) do
    %{
      "type" => schema["type"] || "object",
      "properties" => simplify_properties(schema["properties"] || %{}),
      "required" => schema["required"] || []
    }
  end
  defp simplify_schema(schema), do: schema

  defp simplify_properties(properties) when is_map(properties) do
    properties
    |> Enum.map(fn {key, prop} ->
      simplified_prop = 
        case prop do
          %{"type" => type, "description" => desc} ->
            %{"type" => type, "description" => desc}
          %{"type" => type} ->
            %{"type" => type}
          %{"anyOf" => any_of} when is_list(any_of) ->
            # Handle optional fields with anyOf: [{"type": "string"}, {"type": "null"}]
            type = 
              any_of
              |> Enum.find(%{}, fn t -> t["type"] && t["type"] != "null" end)
              |> Map.get("type", "string")
            %{"type" => type}
          _ ->
            %{"type" => "string"}
        end
      {key, simplified_prop}
    end)
    |> Map.new()
  end
  defp simplify_properties(properties), do: properties

  defp resolve_name_conflicts(tools) do
    # Group tools by name to detect conflicts
    grouped = Enum.group_by(tools, & &1.name)
    
    grouped
    |> Enum.flat_map(fn {_name, tools_with_name} ->
      case tools_with_name do
        [single_tool] ->
          # No conflict, keep original name
          [single_tool]
        multiple_tools ->
          # Name conflict, prefix with server name
          multiple_tools
          |> Enum.map(fn tool ->
            %{tool | name: "#{tool.server_name}.#{tool.name}"}
          end)
      end
    end)
  end

  defp find_tool(tools, tool_name) do
    case Enum.find(tools, &(&1.name == tool_name)) do
      nil -> {:error, "Tool '#{tool_name}' not found"}
      tool -> {:ok, tool}
    end
  end

  @spec list_available_tools() :: {:ok, [map()]} | {:error, term()}
  def list_available_tools do
    with {:ok, tools} <- aggregate_tools() do
      formatted_tools = 
        tools
        |> Enum.map(fn tool ->
          %{
            "name" => tool.name,
            "description" => tool.description,
            "inputSchema" => tool.input_schema
          }
        end)

      {:ok, formatted_tools}
    end
  end

  @spec get_tool_server_tags(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_tool_server_tags(tool_name) do
    with {:ok, tools} <- aggregate_tools(),
         {:ok, tool} <- find_tool(tools, tool_name) do
      {:ok, tool.server_tags}
    end
  end
end