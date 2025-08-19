defmodule McpBroker.Errors do
  @moduledoc """
  Structured error types for the MCP broker.
  
  Provides consistent error handling patterns across the application.
  """

  @type error_reason :: 
    authentication_error() |
    tool_error() |
    config_error() |
    client_error() |
    server_error()

  @type authentication_error :: 
    {:authentication_failed, String.t()} |
    {:invalid_token, String.t()} |
    {:access_denied, String.t()}

  @type tool_error ::
    {:tool_not_found, String.t()} |
    {:tool_execution_failed, String.t(), term()} |
    {:invalid_tool_params, String.t()}

  @type config_error ::
    {:invalid_config, String.t()} |
    {:config_file_not_found, String.t()} |
    {:invalid_command, String.t()} |
    {:invalid_args, String.t()} |
    {:invalid_env, String.t()}

  @type client_error ::
    {:client_not_found, String.t()} |
    {:client_connection_failed, String.t()} |
    {:client_timeout, String.t()} |
    {:port_closed, String.t()}

  @type server_error ::
    {:server_not_available, String.t()} |
    {:initialization_failed, String.t()} |
    {:invalid_response, String.t()}

  @doc """
  Formats an error for logging or display.
  """
  @spec format_error(error_reason()) :: String.t()
  def format_error({:authentication_failed, reason}), do: "Authentication failed: #{reason}"
  def format_error({:invalid_token, reason}), do: "Invalid token: #{reason}"
  def format_error({:access_denied, resource}), do: "Access denied to #{resource}"
  
  def format_error({:tool_not_found, tool_name}), do: "Tool '#{tool_name}' not found"
  def format_error({:tool_execution_failed, tool_name, reason}), do: "Tool '#{tool_name}' failed: #{inspect(reason)}"
  def format_error({:invalid_tool_params, reason}), do: "Invalid tool parameters: #{reason}"
  
  def format_error({:invalid_config, reason}), do: "Invalid configuration: #{reason}"
  def format_error({:config_file_not_found, path}), do: "Configuration file not found: #{path}"
  def format_error({:invalid_command, reason}), do: "Invalid command: #{reason}"
  def format_error({:invalid_args, reason}), do: "Invalid arguments: #{reason}"
  def format_error({:invalid_env, reason}), do: "Invalid environment: #{reason}"
  
  def format_error({:client_not_found, name}), do: "Client '#{name}' not found"
  def format_error({:client_connection_failed, reason}), do: "Client connection failed: #{reason}"
  def format_error({:client_timeout, name}), do: "Client '#{name}' timed out"
  def format_error({:port_closed, name}), do: "Port closed for client '#{name}'"
  
  def format_error({:server_not_available, name}), do: "Server '#{name}' not available"
  def format_error({:initialization_failed, reason}), do: "Initialization failed: #{reason}"
  def format_error({:invalid_response, reason}), do: "Invalid response: #{reason}"
  
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  @doc """
  Converts a legacy string error to a structured error.
  """
  @spec normalize_error(term()) :: {:error, error_reason()}
  def normalize_error({:error, reason}) when is_atom(reason) or is_tuple(reason) do
    {:error, reason}
  end
  def normalize_error({:error, reason}) when is_binary(reason) do
    # Try to classify string errors
    cond do
      String.contains?(reason, "not found") ->
        {:error, {:tool_not_found, reason}}
      String.contains?(reason, "timeout") ->
        {:error, {:client_timeout, reason}}
      String.contains?(reason, "authentication") or String.contains?(reason, "auth") ->
        {:error, {:authentication_failed, reason}}
      String.contains?(reason, "config") ->
        {:error, {:invalid_config, reason}}
      true ->
        {:error, {:server_error, reason}}
    end
  end
  def normalize_error(error) do
    {:error, {:server_error, inspect(error)}}
  end
end