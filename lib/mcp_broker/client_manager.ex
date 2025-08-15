defmodule McpBroker.ClientManager do
  @moduledoc """
  Manages multiple MCP clients dynamically based on configuration.
  """

  use GenServer
  require Logger

  alias McpBroker.Config
  alias McpBroker.DirectClient

  @type state :: %{
    clients: %{String.t() => {pid(), map()}},
    config: Config.config()
  }

  def start_link(config_path) do
    GenServer.start_link(__MODULE__, config_path, name: __MODULE__)
  end

  @spec list_all_tools() :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def list_all_tools do
    GenServer.call(__MODULE__, :list_all_tools)
  end

  @spec call_tool(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(server_name, tool_name, arguments) do
    GenServer.call(__MODULE__, {:call_tool, server_name, tool_name, arguments}, 30_000)
  end

  @spec get_client_info() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def get_client_info do
    GenServer.call(__MODULE__, :get_client_info)
  end

  @impl true
  def init(config_path) do
    with {:ok, config} <- Config.load_config(config_path),
         {:ok, clients} <- start_clients(config.servers) do
      {:ok, %{clients: clients, config: config}}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize ClientManager: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_all_tools, _from, state) do
    result = 
      state.clients
      |> Enum.map(fn {server_name, {pid, _info}} ->
        case DirectClient.list_tools(pid) do
          {:ok, tools} -> 
            Logger.debug("Got #{length(tools)} tools from #{server_name}")
            {server_name, tools}
          {:error, reason} -> 
            Logger.debug("Failed to get tools from #{server_name}: #{inspect(reason)}")
            {server_name, []}
        end
      end)
      |> Map.new()

    {:reply, {:ok, result}, state}
  end

  def handle_call({:call_tool, server_name, tool_name, arguments}, _from, state) do
    case Map.get(state.clients, server_name) do
      {pid, _info} ->
        result = DirectClient.call_tool(pid, tool_name, arguments)
        {:reply, result, state}
      nil ->
        {:reply, {:error, "Server '#{server_name}' not found"}, state}
    end
  end

  def handle_call(:get_client_info, _from, state) do
    info = 
      state.clients
      |> Enum.map(fn {server_name, {_pid, info}} ->
        {server_name, info}
      end)
      |> Map.new()

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find which client crashed
    crashed_client = 
      state.clients
      |> Enum.find(fn {_name, {client_pid, _info}} -> client_pid == pid end)
    
    case crashed_client do
      {client_name, _} ->
        Logger.warning("MCP client '#{client_name}' crashed: #{inspect(reason)}")
        Logger.info("Removing '#{client_name}' from available clients - service continues with remaining clients")
        
        # Remove the crashed client from state
        new_clients = Map.delete(state.clients, client_name)
        new_state = %{state | clients: new_clients}
        
        {:noreply, new_state}
      
      nil ->
        Logger.debug("Unknown process #{inspect(pid)} crashed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp start_clients(server_configs) do
    # Start clients individually, don't fail if some don't start
    successful_clients = 
      server_configs
      |> Enum.reduce(%{}, fn {_name, config}, acc ->
        case start_client(config) do
          {:ok, pid, client_info} ->
            Map.put(acc, config.name, {pid, client_info})
          {:error, reason} ->
            Logger.error("Failed to start client '#{config.name}': #{inspect(reason)}")
            Logger.info("Continuing without '#{config.name}' - other MCP servers will still work")
            acc
        end
      end)
    
    if map_size(successful_clients) == 0 do
      Logger.error("No MCP clients started successfully")
      {:error, :no_clients_started}
    else
      Logger.info("Started #{map_size(successful_clients)} MCP client(s) successfully")
      {:ok, successful_clients}
    end
  end

  defp start_client(config) do
    Logger.info("Starting MCP client '#{config.name}' with command: #{config.command} #{Enum.join(config.args, " ")}")
    
    case DirectClient.start_link(config) do
      {:ok, pid} ->
        Logger.info("Successfully started MCP client '#{config.name}' with PID: #{inspect(pid)}")
        
        # Monitor the client process so we can handle crashes
        Process.monitor(pid)
        
        # Give the client time to complete MCP handshake
        Process.sleep(2000)
        
        client_info_result = %{
          name: config.name,
          command: config.command,
          args: config.args,
          env: config.env,
          type: config.type,
          tags: config.tags
        }
        {:ok, pid, client_info_result}
      error ->
        Logger.error("Failed to start MCP client '#{config.name}': #{inspect(error)}")
        error
    end
  end

end