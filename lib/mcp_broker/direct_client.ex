defmodule McpBroker.DirectClient do
  @moduledoc """
  Direct STDIO MCP client implementation that bypasses Hermes.Client.Base.
  
  This implements the MCP protocol directly over STDIO to work around
  compatibility issues with the Hermes client library.
  """
  
  use GenServer
  require Logger
  
  @type state :: %{
    config: map(),
    port: port(),
    id_counter: integer(),
    pending_requests: %{integer() => pid()},
    server_info: map() | nil,
    tools: [map()],
    buffer: String.t()
  }
  
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end
  
  def list_tools(pid) do
    GenServer.call(pid, :list_tools, 10_000)
  end
  
  def call_tool(pid, tool_name, arguments) do
    GenServer.call(pid, {:call_tool, tool_name, arguments}, 30_000)
  end
  
  @impl true
  def init(config) do
    # Trap exits to handle port crashes gracefully
    Process.flag(:trap_exit, true)
    
    Logger.info("Starting direct MCP client for '#{config.name}'")
    
    # Validate and sanitize configuration before starting process
    case validate_and_sanitize_config(config) do
      {:ok, sanitized_config} ->
        # Start the MCP server process with sanitized config
        port = Port.open({:spawn_executable, sanitized_config.command}, [
          :binary,
          :stderr_to_stdout,
          {:args, sanitized_config.args},
          {:env, Enum.map(sanitized_config.env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
          {:line, 8192}
        ])
        
        create_initial_state(sanitized_config, port)
      
      {:error, reason} ->
        error_msg = if is_tuple(reason), do: McpBroker.Errors.format_error(reason), else: reason
        Logger.error("Failed to validate MCP client config for '#{config.name}': #{error_msg}")
        {:stop, {:invalid_config, reason}}
    end
  end

  defp create_initial_state(config, port) do
    state = %{
      config: config,
      port: port,
      id_counter: 1,
      pending_requests: %{},
      server_info: nil,
      tools: [],
      buffer: ""
    }
    
    # Initialize the MCP connection with timeout
    send(self(), :initialize)
    Process.send_after(self(), :initialization_timeout, 10_000)
    
    {:ok, state}
  end

  defp validate_and_sanitize_config(config) do
    with {:ok, command} <- validate_command(config.command),
         {:ok, args} <- validate_args(config.args),
         {:ok, env} <- validate_env_vars(config.env) do
      sanitized_config = %{
        config | 
        command: command,
        args: args,
        env: env
      }
      {:ok, sanitized_config}
    end
  end

  defp validate_command(command) when is_binary(command) do
    # Only allow whitelisted executables or absolute paths in safe directories
    safe_executables = ~w[uvx python3 python node npm npx uv]
    safe_directories = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/etc/profiles", "/run"]
    
    cond do
      Enum.member?(safe_executables, command) ->
        {:ok, command}
      
      String.starts_with?(command, "/") ->
        # Absolute path - validate it's in a safe directory
        if Enum.any?(safe_directories, &String.starts_with?(command, &1)) do
          if File.exists?(command) and File.regular?(command) do
            {:ok, command}
          else
            {:error, {:invalid_command, "Command file does not exist or is not a regular file"}}
          end
        else
          {:error, {:invalid_command, "Command path not in allowed directories"}}
        end
      
      true ->
        {:error, {:invalid_command, "Command must be whitelisted or an absolute path in safe directory"}}
    end
  end
  defp validate_command(_), do: {:error, {:invalid_command, "Command must be a string"}}

  defp validate_args(args) when is_list(args) do
    # Validate each argument
    if Enum.all?(args, &is_binary/1) and length(args) <= 50 do
      # Basic sanitization - reject arguments with shell metacharacters
      dangerous_chars = ["&", "|", ";", "`", "$", "(", ")", "<", ">"]
      
      safe_args = Enum.reject(args, fn arg ->
        Enum.any?(dangerous_chars, &String.contains?(arg, &1))
      end)
      
      if length(safe_args) == length(args) do
        {:ok, args}
      else
        {:error, {:invalid_args, "Arguments contain dangerous shell characters"}}
      end
    else
      {:error, {:invalid_args, "Too many arguments or non-string arguments"}}
    end
  end
  defp validate_args(_), do: {:error, {:invalid_args, "Args must be a list"}}

  defp validate_env_vars(env) when is_map(env) do
    if map_size(env) <= 20 do
      # Validate environment variable names and values
      valid_env = Enum.all?(env, fn {key, value} ->
        is_binary(key) and is_binary(value) and
        Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, key) and
        byte_size(value) <= 1000
      end)
      
      if valid_env do
        {:ok, env}
      else
        {:error, {:invalid_env, "Invalid environment variable names or values"}}
      end
    else
      {:error, {:invalid_env, "Too many environment variables"}}
    end
  end
  defp validate_env_vars(_), do: {:error, {:invalid_env, "Environment must be a map"}}
  
  @impl true
  def handle_info(:initialize, state) do
    # Send initialize request
    request = %{
      "jsonrpc" => "2.0",
      "id" => state.id_counter,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{},
          "resources" => %{},
          "prompts" => %{}
        },
        "clientInfo" => %{
          "name" => "McpBroker",
          "version" => "0.1.0"
        }
      }
    }
    
    send_request(state.port, request)
    
    new_state = %{state | 
      id_counter: state.id_counter + 1,
      pending_requests: Map.put(state.pending_requests, state.id_counter, :initialize)
    }
    
    {:noreply, new_state}
  end
  
  @impl true  
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    # Process complete line (with buffer if any)
    complete_line = state.buffer <> line
    new_state = %{state | buffer: ""}
    process_complete_line(complete_line, new_state)
  end
  
  @impl true
  def handle_info({port, {:data, {:noeol, data}}}, %{port: port} = state) do
    # Buffer partial data
    new_state = %{state | buffer: state.buffer <> data}
    {:noreply, new_state}
  end
  
  @impl true
  def handle_info(:request_tools, state) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => state.id_counter,
      "method" => "tools/list"
    }
    
    send_request(state.port, request)
    
    new_state = %{state | 
      id_counter: state.id_counter + 1,
      pending_requests: Map.put(state.pending_requests, state.id_counter, :tools_list)
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:initialization_timeout, state) do
    if state.server_info == nil do
      Logger.error("MCP client '#{state.config.name}' failed to initialize within timeout")
      {:stop, :initialization_timeout, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("MCP client '#{state.config.name}' port exited: #{inspect(reason)}")
    # Reply to any pending requests with error
    Enum.each(state.pending_requests, fn {_id, from} ->
      if is_tuple(from) do
        GenServer.reply(from, {:error, :port_closed})
      end
    end)
    {:stop, {:port_exit, reason}, state}
  end
  
  defp process_complete_line(line, state) do
    # Skip non-JSON lines (logs, errors, etc.)
    trimmed_line = String.trim(line)
    if String.starts_with?(trimmed_line, "{") do
      try do
        case Jason.decode(trimmed_line) do
          {:ok, message} ->
            handle_mcp_message(message, state)
          {:error, reason} ->
            Logger.debug("Failed to parse JSON: #{inspect(reason)}, line: #{String.slice(trimmed_line, 0, 100)}...")
            {:noreply, state}
        end
      rescue
        e ->
          Logger.error("Error processing MCP message: #{inspect(e)}, line: #{String.slice(trimmed_line, 0, 100)}...")
          {:noreply, state}
      end
    else
      # Log non-JSON output as debug (likely stderr or status messages)
      unless String.trim(line) == "" do
        Logger.debug("Non-JSON output from #{state.config.name}: #{line}")
      end
      {:noreply, state}
    end
  end
  
  
  @impl true
  def handle_call(:list_tools, from, state) do
    if length(state.tools) > 0 do
      {:reply, {:ok, state.tools}, state}
    else
      # Request tools
      request = %{
        "jsonrpc" => "2.0",
        "id" => state.id_counter,
        "method" => "tools/list"
      }
      
      send_request(state.port, request)
      
      new_state = %{state | 
        id_counter: state.id_counter + 1,
        pending_requests: Map.put(state.pending_requests, state.id_counter, from)
      }
      
      {:noreply, new_state}
    end
  end
  
  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => state.id_counter,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    }
    
    send_request(state.port, request)
    
    new_state = %{state | 
      id_counter: state.id_counter + 1,
      pending_requests: Map.put(state.pending_requests, state.id_counter, from)
    }
    
    {:noreply, new_state}
  end
  
  defp handle_mcp_message(%{"id" => id, "result" => result}, state) do
    case Map.get(state.pending_requests, id) do
      :initialize ->
        Logger.info("MCP client '#{state.config.name}' initialized: #{inspect(result["serverInfo"])}")
        # Send initialized notification
        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        }
        send_request(state.port, notification)
        
        new_state = %{state | 
          server_info: result["serverInfo"],
          pending_requests: Map.delete(state.pending_requests, id)
        }
        
        # Auto-request tools after initialization
        Process.send_after(self(), :request_tools, 100)
        
        {:noreply, new_state}
        
      :tools_list ->
        # Handle automatic tools list response
        new_state = %{state | 
          tools: result["tools"] || [],
          pending_requests: Map.delete(state.pending_requests, id)
        }
        {:noreply, new_state}
        
      from when is_tuple(from) ->
        # Handle tools/list response from client call (from is {pid, ref})
        if result["tools"] do
          new_state = %{state | 
            tools: result["tools"],
            pending_requests: Map.delete(state.pending_requests, id)
          }
          GenServer.reply(from, {:ok, result["tools"]})
          {:noreply, new_state}
        else
          # Other responses (like tool calls)
          new_state = %{state | pending_requests: Map.delete(state.pending_requests, id)}
          GenServer.reply(from, {:ok, result})
          {:noreply, new_state}
        end
        
      nil ->
        Logger.debug("Received response for unknown request ID #{id}")
        {:noreply, state}
    end
  end
  
  defp handle_mcp_message(%{"id" => id, "error" => error}, state) do
    Logger.error("MCP error: #{inspect(error)}")
    
    case Map.get(state.pending_requests, id) do
      from when is_tuple(from) ->
        # Reply with error to pending caller
        new_state = %{state | pending_requests: Map.delete(state.pending_requests, id)}
        GenServer.reply(from, {:error, error})
        {:noreply, new_state}
      _ ->
        new_state = %{state | pending_requests: Map.delete(state.pending_requests, id)}
        {:noreply, new_state}
    end
  end
  
  defp handle_mcp_message(%{"error" => error}, state) do
    Logger.error("MCP error (no ID): #{inspect(error)}")
    {:noreply, state}
  end
  
  defp handle_mcp_message(message, state) do
    Logger.debug("Unhandled MCP message: #{inspect(message)}")
    {:noreply, state}
  end
  
  defp send_request(port, request) do
    if Port.info(port) do
      json = Jason.encode!(request)
      Port.command(port, json <> "\n")
    else
      Logger.warning("Attempted to send to closed port")
    end
  end
  
  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port) do
      Port.close(state.port)
    end
  end
end