defmodule McpBroker.Auth.JWTTest do
  use ExUnit.Case
  doctest McpBroker.Auth.JWT

  alias McpBroker.Auth.JWT

  describe "JWT token generation and verification" do
    test "generates and verifies valid tokens" do
      subject = "test-client"
      allowed_tags = ["api", "public"]

      # Generate token
      case JWT.generate_token(subject, allowed_tags) do
        {:ok, token} ->
          assert is_binary(token)

          # Verify token
          assert {:ok, claims} = JWT.verify_token(token)
          assert claims["sub"] == subject
          assert claims["allowed_tags"] == allowed_tags
          assert claims["iss"] == "mcp-broker"
          assert claims["aud"] == "mcp-broker"

        {:error, reason} ->
          flunk("Failed to generate token: #{inspect(reason)}")
      end
    end

    test "extracts allowed tags from claims" do
      claims = %{"allowed_tags" => ["api", "public", "testing"]}
      assert JWT.get_allowed_tags(claims) == ["api", "public", "testing"]

      # Handle missing tags
      assert JWT.get_allowed_tags(%{}) == []
    end

    test "extracts client info from claims" do
      claims = %{
        "sub" => "test-client",
        "allowed_tags" => ["api", "public"]
      }

      client_info = JWT.get_client_info(claims)
      assert client_info.subject == "test-client"
      assert client_info.allowed_tags == ["api", "public"]
    end

    test "validates required claims during verification" do
      # Generate a token with invalid data by bypassing our generate_token function
      claims = %{
        "iss" => "mcp-broker",
        "aud" => "mcp-broker", 
        "sub" => "test",
        "allowed_tags" => ["valid", 123], # Invalid: contains non-string
        "exp" => DateTime.utc_now() |> DateTime.add(30 * 24 * 60 * 60) |> DateTime.to_unix(),
        "iat" => DateTime.utc_now() |> DateTime.to_unix()
      }

      # Create a simple signer for testing
      signer = Joken.Signer.create("HS256", "test-secret")
      {:ok, invalid_token, _} = Joken.encode_and_sign(claims, signer)

      # Verification should fail due to invalid allowed_tags
      case JWT.verify_token(invalid_token) do
        {:error, _} -> :ok
        {:ok, _} -> flunk("Expected validation error for invalid allowed_tags")
      end
    end
  end
end