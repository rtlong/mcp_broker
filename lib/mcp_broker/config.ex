defmodule McpBroker.Config do
  @moduledoc """
  Configuration loading and validation for MCP broker.
  """

  @type server_config :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          type: String.t(),
          tags: [String.t()]
        }

  @type config :: %{
          servers: %{String.t() => server_config()}
        }

  @spec load_config() :: {:ok, config()} | {:error, term()}
  def load_config(), do: load_config(nil)

  @spec load_config(String.t() | nil) :: {:ok, config()} | {:error, term()}
  def load_config(path) do
    config_path = resolve_config_path(path)

    with {:ok, expanded_path} <- expand_path(config_path),
         {:ok, content} <- File.read(expanded_path),
         {:ok, json} <- Jason.decode(content),
         {:ok, config} <- validate_config(json) do
      {:ok, config}
    end
  end

  @spec resolve_config_path(String.t() | nil) :: String.t()
  defp resolve_config_path(nil) do
    System.get_env("MCP_CONFIG_PATH") || default_config_path()
  end

  defp resolve_config_path(path), do: path

  @spec default_config_path() :: String.t()
  defp default_config_path() do
    # In test environment, use test-specific config
    case Mix.env() do
      :test ->
        "test_config.json"
      
      _ ->
        xdg_config_home = System.get_env("XDG_CONFIG_HOME")

        candidates =
          cond do
            xdg_config_home && xdg_config_home != "" ->
              [Path.join([xdg_config_home, "mcp_broker", "config.json"]), "config.json"]

            home = System.get_env("HOME") ->
              [Path.join([home, ".config", "mcp_broker", "config.json"]), "config.json"]

            true ->
              ["config.json"]
          end

        # Return the first existing file, or the first candidate if none exist
        Enum.find(candidates, &File.exists?/1) || hd(candidates)
    end
  end

  @spec expand_path(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp expand_path("~" <> rest) do
    case System.get_env("HOME") do
      nil -> {:error, "HOME environment variable not set"}
      home -> {:ok, Path.join(home, rest)}
    end
  end

  defp expand_path(path), do: {:ok, path}

  @spec expand_paths_in_list([String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  defp expand_paths_in_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case expand_path(item) do
        {:ok, expanded_item} -> {:cont, {:ok, [expanded_item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed_list} -> {:ok, Enum.reverse(reversed_list)}
      error -> error
    end
  end

  @spec validate_config(map()) :: {:ok, config()} | {:error, String.t()}
  def validate_config(%{"mcpServers" => servers}) when is_map(servers) do
    case validate_servers(servers) do
      {:ok, validated_servers} ->
        {:ok, %{servers: validated_servers}}

      error ->
        error
    end
  end

  def validate_config(_), do: {:error, "Config must have 'mcpServers' object"}

  defp validate_servers(servers) do
    servers
    |> Enum.reduce_while({:ok, %{}}, fn {name, server_config}, {:ok, acc} ->
      case validate_server(server_config, name) do
        {:ok, validated_server} -> {:cont, {:ok, Map.put(acc, name, validated_server)}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_server(server, name) when is_map(server) do
    with {:ok, command} <- get_required_string(server, "command", name),
         {:ok, expanded_command} <- expand_path(command),
         {:ok, args} <- get_optional_list(server, "args", name, []),
         {:ok, expanded_args} <- expand_paths_in_list(args),
         {:ok, env} <- get_optional_map(server, "env", name, %{}),
         {:ok, type} <- get_optional_string(server, "type", name, "stdio"),
         {:ok, tags} <- get_optional_list(server, "tags", name, []) do
      {:ok,
       %{
         name: name,
         command: expanded_command,
         args: expanded_args,
         env: env,
         type: type,
         tags: tags
       }}
    end
  end

  defp validate_server(_, name), do: {:error, "Server '#{name}' must be an object"}

  defp get_required_string(map, key, name) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, "Server '#{name}' missing required field '#{key}'"}
      _ -> {:error, "Server '#{name}' field '#{key}' must be a string"}
    end
  end

  defp get_optional_string(map, key, name, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Server '#{name}' field '#{key}' must be a string"}
    end
  end

  defp get_optional_list(map, key, name, default) do
    case Map.get(map, key, default) do
      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          {:ok, value}
        else
          {:error, "Server '#{name}' field '#{key}' must be array of strings"}
        end

      _ ->
        {:error, "Server '#{name}' field '#{key}' must be an array"}
    end
  end

  defp get_optional_map(map, key, name, default) do
    case Map.get(map, key, default) do
      value when is_map(value) ->
        if Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, value}
        else
          {:error, "Server '#{name}' field '#{key}' must be object with string values"}
        end

      _ ->
        {:error, "Server '#{name}' field '#{key}' must be an object"}
    end
  end
end
