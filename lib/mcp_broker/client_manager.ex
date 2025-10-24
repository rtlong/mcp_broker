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

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec list_all_tools() :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def list_all_tools do
    GenServer.call(__MODULE__, :list_all_tools, 15_000)
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
  def init(_opts) do
    with {:ok, config} <- Config.load_config(),
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
    Logger.debug("Listing tools from #{map_size(state.clients)} clients: #{Map.keys(state.clients) |> Enum.join(", ")}")
    
    # Check client process health first
    alive_clients = 
      state.clients
      |> Enum.filter(fn {server_name, {pid, _info}} ->
        if Process.alive?(pid) do
          true
        else
          Logger.warning("Client #{server_name} process #{inspect(pid)} is not alive, skipping")
          false
        end
      end)
    
    Logger.debug("#{length(alive_clients)} clients are alive")
    
    # Use Task.async_stream for concurrent client queries on alive clients
    result = 
      alive_clients
      |> Task.async_stream(
        fn {server_name, {pid, _info}} ->
          try do
            Logger.debug("Requesting tools from #{server_name} (PID: #{inspect(pid)})")
            case DirectClient.list_tools(pid) do
              {:ok, tools} -> 
                Logger.debug("Got #{length(tools)} tools from #{server_name}")
                {server_name, tools}
              {:error, reason} -> 
                Logger.warning("Failed to get tools from #{server_name}: #{inspect(reason)}")
                {server_name, []}
            end
          catch
            :exit, {:timeout, _} ->
              Logger.warning("Timeout getting tools from #{server_name}")
              {server_name, []}
            :exit, reason ->
              Logger.warning("Process exit getting tools from #{server_name}: #{inspect(reason)}")
              {server_name, []}
          end
        end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {server_name, tools}}, acc -> Map.put(acc, server_name, tools)
        {:exit, reason}, acc -> 
          Logger.warning("Task failed to list tools: #{inspect(reason)}")
          acc
      end)

    Logger.debug("Tool collection complete: #{inspect(Map.keys(result))}")
    {:reply, {:ok, result}, state}
  end

  def handle_call({:call_tool, server_name, tool_name, arguments}, _from, state) do
    case Map.get(state.clients, server_name) do
      {pid, _info} ->
        result = DirectClient.call_tool(pid, tool_name, arguments)
        {:reply, result, state}
      nil ->
        {:reply, {:error, {:client_not_found, server_name}}, state}
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
      {client_name, {_pid, client_info}} ->
        Logger.warning("MCP client '#{client_name}' crashed: #{inspect(reason)}")
        
        # Remove the crashed client from state immediately
        new_clients = Map.delete(state.clients, client_name)
        new_state = %{state | clients: new_clients}
        
        # Schedule a reconnection attempt after a delay
        if reason != :normal and reason != :shutdown do
          Logger.info("Scheduling reconnection attempt for '#{client_name}' in 5 seconds")
          Process.send_after(self(), {:reconnect_client, client_name, client_info, 1}, 5000)
        else
          Logger.info("Client '#{client_name}' shutdown gracefully, not attempting reconnection")
        end
        
        {:noreply, new_state}
      
      nil ->
        Logger.debug("Unknown process #{inspect(pid)} crashed: #{inspect(reason)}")
        {:noreply, state}
    end
  end
  
  @impl true
  def handle_info({:reconnect_client, client_name, client_info, attempt}, state) do
    # Don't reconnect if client was manually removed or already reconnected
    if Map.has_key?(state.clients, client_name) do
      Logger.debug("Client '#{client_name}' already reconnected, skipping")
      {:noreply, state}
    else
      Logger.info("Attempting to reconnect MCP client '#{client_name}' (attempt #{attempt})")
      
      # Create a config-like structure for reconnection
      config = %{
        name: client_info.name,
        command: client_info.command,
        args: client_info.args,
        env: client_info.env,
        type: client_info.type,
        tags: client_info.tags
      }
      
      case start_client_with_retry(config, 2) do  # Fewer retries for reconnection
        {:ok, pid, new_client_info} ->
          Logger.info("Successfully reconnected MCP client '#{client_name}' after #{attempt} attempt(s)")
          new_clients = Map.put(state.clients, client_name, {pid, new_client_info})
          new_state = %{state | clients: new_clients}
          {:noreply, new_state}
        
        {:error, reason} ->
          if attempt < 5 do  # Limit to 5 reconnection attempts
            backoff_delay = calculate_reconnect_backoff_delay(attempt)
            Logger.error("Failed to reconnect client '#{client_name}' (attempt #{attempt}): #{inspect(reason)}")
            Logger.info("Will retry reconnection for '#{client_name}' in #{backoff_delay / 1000} seconds (exponential backoff)")
            Process.send_after(self(), {:reconnect_client, client_name, client_info, attempt + 1}, backoff_delay)
            {:noreply, state}
          else
            Logger.error("Failed to reconnect client '#{client_name}' after #{attempt} attempts, giving up: #{inspect(reason)}")
            Logger.warning("Client '#{client_name}' will not be automatically reconnected further")
            {:noreply, state}
          end
      end
    end
  end
  
  # Calculate exponential backoff delay for reconnection: 30s, 60s, 120s, 240s, 480s
  defp calculate_reconnect_backoff_delay(attempt) do
    base_delay = 30_000  # 30 seconds base
    min(round(base_delay * :math.pow(2, attempt - 1)), 480_000)  # Cap at 8 minutes
  end

  defp start_clients(server_configs) do
    # Start clients individually with retry logic, don't fail if some don't start
    successful_clients = 
      server_configs
      |> Enum.reduce(%{}, fn {_name, config}, acc ->
        case start_client_with_retry(config, 3) do
          {:ok, pid, client_info} ->
            Map.put(acc, config.name, {pid, client_info})
          {:error, reason} ->
            Logger.error("Failed to start client '#{config.name}' after retries: #{inspect(reason)}")
            Logger.info("Continuing without '#{config.name}' - other MCP servers will still work")
            acc
        end
      end)
    
    if map_size(successful_clients) == 0 do
      if Mix.env() == :test do
        Logger.info("No MCP clients configured for test environment")
        {:ok, %{}}
      else
        Logger.warning("No MCP clients started successfully - broker will start with no tools available")
        Logger.info("You can check configuration and restart to enable MCP servers")
        {:ok, %{}}
      end
    else
      total_configured = map_size(server_configs)
      successful_count = map_size(successful_clients)
      failed_count = total_configured - successful_count
      
      Logger.info("Started #{successful_count}/#{total_configured} MCP client(s) successfully")
      if failed_count > 0 do
        Logger.warning("#{failed_count} MCP client(s) failed to start but broker is operational with available clients")
      end
      {:ok, successful_clients}
    end
  end
  
  defp start_client_with_retry(config, retries_left) when retries_left > 0 do
    case start_client(config) do
      {:ok, pid, client_info} -> 
        {:ok, pid, client_info}
      {:error, reason} when retries_left > 1 ->
        attempt_number = 4 - retries_left
        backoff_delay = calculate_backoff_delay(attempt_number)
        Logger.warning("Failed to start client '#{config.name}' (attempt #{attempt_number}/3): #{inspect(reason)}")
        Logger.info("Retrying in #{backoff_delay / 1000} seconds with exponential backoff...")
        Process.sleep(backoff_delay)
        start_client_with_retry(config, retries_left - 1)
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp start_client_with_retry(_config, 0) do
    {:error, :no_retries_left}
  end
  
  # Calculate exponential backoff delay: 5s, 15s, 45s
  defp calculate_backoff_delay(attempt_number) do
    base_delay = 5_000  # 5 seconds base
    round(base_delay * :math.pow(3, attempt_number - 1))
  end

  defp start_client(config) do
    Logger.info("Starting MCP client '#{config.name}' with command: #{config.command} #{Enum.join(config.args, " ")}")
    
    case DirectClient.start_link(config) do
      {:ok, pid} ->
        Logger.info("Successfully started MCP client '#{config.name}' with PID: #{inspect(pid)}")
        
        # Monitor the client process so we can handle crashes
        Process.monitor(pid)
        
        # Minimal delay to let initialization complete
        Process.sleep(1000)
        
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