defmodule McpBroker.Auth.JWT do
  @moduledoc """
  JWT token generation and verification for MCP broker authentication.
  
  Handles RSA256-signed tokens containing client authentication claims including
  allowed server tags for access control.
  """

  use Joken.Config
  import Bitwise

  # Default token configuration
  @default_iss "mcp-broker"
  @default_aud "mcp-broker"
  @default_exp_seconds 30 * 24 * 60 * 60  # 30 days

  # RSA key paths - configurable via environment variable
  defp get_private_key_path do
    System.get_env("MCP_JWT_PRIVATE_KEY_PATH", 
      Path.join([__DIR__, "..", "..", "..", "config", "jwt_keys", "private_key.pem"])
    )
  end

  @impl Joken.Config
  def token_config do
    default_claims(default_exp: @default_exp_seconds)
    |> add_claim("iss", fn -> @default_iss end)
    |> add_claim("aud", fn -> @default_aud end)
  end

  @doc """
  Generates a JWT token for a client with specified allowed tags.
  """
  def generate_token(subject, allowed_tags) when is_list(allowed_tags) do
    claims = %{
      "sub" => subject,
      "allowed_tags" => allowed_tags
    }

    case generate_and_sign(claims, get_signer()) do
      {:ok, token, _claims} -> {:ok, token}
      error -> error
    end
  end

  @doc """
  Verifies a JWT token and returns the claims if valid.
  """
  def verify_token(token) do
    case verify_and_validate(token, get_signer()) do
      {:ok, claims} ->
        # Manually validate our custom claims
        case validate_custom_claims(claims) do
          :ok -> {:ok, claims}
          {:error, reason} -> {:error, reason}
        end
      error ->
        error
    end
  end

  @doc """
  Extracts allowed tags from a verified token's claims.
  """
  def get_allowed_tags(%{"allowed_tags" => tags}) when is_list(tags), do: tags
  def get_allowed_tags(_), do: []

  @doc """
  Extracts client information from verified token claims.
  """
  def get_client_info(claims) do
    %{
      subject: Map.get(claims, "sub"),
      allowed_tags: get_allowed_tags(claims)
    }
  end

  # Private functions

  defp get_signer do
    case read_private_key() do
      {:ok, private_key} ->
        Joken.Signer.create("RS256", %{"pem" => private_key})
      {:error, reason} ->
        raise "Failed to load JWT private key: #{reason}"
    end
  end

  defp read_private_key do
    private_key_path = get_private_key_path()
    
    if File.exists?(private_key_path) do
      case File.read(private_key_path) do
        {:ok, content} -> 
          # Validate file permissions for security
          case validate_key_file_permissions(private_key_path) do
            :ok -> {:ok, content}
            {:error, reason} -> {:error, reason}
          end
        {:error, reason} -> 
          {:error, "Cannot read private key file: #{reason}"}
      end
    else
      {:error, "Private key file not found at #{private_key_path}"}
    end
  end

  defp validate_key_file_permissions(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        # Extract permission bits (last 9 bits)
        permissions = mode &&& 0o777
        
        case permissions do
          0o600 -> :ok  # Only owner can read/write
          0o400 -> :ok  # Only owner can read (also acceptable)
          _ -> 
            {:error, "Private key file has insecure permissions (#{Integer.to_string(permissions, 8)}). Expected 600 or 400."}
        end
      
      {:error, reason} ->
        {:error, "Cannot check file permissions: #{reason}"}
    end
  end

  # Manual validation for custom claims
  defp validate_custom_claims(claims) do
    case Map.get(claims, "allowed_tags") do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          :ok
        else
          {:error, "allowed_tags must be a list of strings"}
        end
      nil ->
        {:error, "allowed_tags is required"}
      _ ->
        {:error, "allowed_tags must be a list"}
    end
  end

end