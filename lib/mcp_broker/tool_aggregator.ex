defmodule McpBroker.ToolAggregator do
  @moduledoc """
  Aggregates tools from multiple MCP clients and handles name conflicts.
  Implements caching with TTL for performance.
  """

  use GenServer
  alias McpBroker.ClientManager
  
  # Cache TTL in milliseconds (5 minutes)
  @cache_ttl 5 * 60 * 1000
  @cache_table :tool_aggregator_cache

  @type tool_with_source :: %{
    name: String.t(),
    description: String.t(),
    input_schema: map(),
    server_name: String.t(),
    original_name: String.t(),
    server_tags: [String.t()]
  }

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec aggregate_tools() :: {:ok, [tool_with_source()]} | {:error, term()}
  def aggregate_tools do
    GenServer.call(__MODULE__, :get_tools)
  end

  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    GenServer.cast(__MODULE__, :invalidate_cache)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@cache_table, [:set, :protected, :named_table])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:get_tools, _from, state) do
    result = get_cached_tools()
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:invalidate_cache, state) do
    :ets.delete_all_objects(@cache_table)
    {:noreply, state}
  end

  # Private functions

  defp get_cached_tools do
    current_time = System.system_time(:millisecond)
    
    case :ets.lookup(@cache_table, :tools) do
      [{:tools, tools, cached_at}] when current_time - cached_at < @cache_ttl ->
        {:ok, tools}
      
      _ ->
        # Cache miss or expired, refresh
        refresh_tools_cache()
    end
  end

  defp refresh_tools_cache do
    case do_aggregate_tools() do
      {:ok, tools} ->
        # Cache the tools with timestamp
        current_time = System.system_time(:millisecond)
        :ets.insert(@cache_table, {:tools, tools, current_time})
        {:ok, tools}
      
      error ->
        error
    end
  end

  defp do_aggregate_tools do
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
      nil -> {:error, {:tool_not_found, tool_name}}
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