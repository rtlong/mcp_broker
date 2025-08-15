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

  @spec load_config(String.t()) :: {:ok, config()} | {:error, term()}
  def load_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content),
         {:ok, config} <- validate_config(json) do
      {:ok, config}
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
         {:ok, args} <- get_optional_list(server, "args", name, []),
         {:ok, env} <- get_optional_map(server, "env", name, %{}),
         {:ok, type} <- get_optional_string(server, "type", name, "stdio"),
         {:ok, tags} <- get_optional_list(server, "tags", name, []) do
      {:ok, %{
        name: name,
        command: command,
        args: args,
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
      _ -> {:error, "Server '#{name}' field '#{key}' must be an array"}
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
      _ -> {:error, "Server '#{name}' field '#{key}' must be an object"}
    end
  end
end