defmodule McpBroker.Auth.ClientContextTest do
  use ExUnit.Case
  doctest McpBroker.Auth.ClientContext

  alias McpBroker.Auth.ClientContext

  describe "client context creation and access control" do
    test "creates context from JWT claims" do
      claims = %{
        "sub" => "claude-code",
        "allowed_tags" => ["api", "public", "coding"]
      }

      context = ClientContext.from_jwt_claims(claims)

      assert context.subject == "claude-code"
      assert context.allowed_tags == ["api", "public", "coding"]
      assert %DateTime{} = context.authenticated_at
    end

    test "checks access to multiple tags" do
      context = %ClientContext{
        allowed_tags: ["api", "public", "coding"],
        subject: "test-client",
        authenticated_at: DateTime.utc_now()
      }

      # Has access to any of the required tags
      assert ClientContext.has_access_to_tags?(context, ["api", "private"])
      assert ClientContext.has_access_to_tags?(context, ["coding"])
      assert ClientContext.has_access_to_tags?(context, ["public", "coding"])

      # No access if none of the tags match
      refute ClientContext.has_access_to_tags?(context, ["private", "admin"])
    end

    test "checks access to single tag" do
      context = %ClientContext{
        allowed_tags: ["api", "public", "coding"],
        subject: "test-client",
        authenticated_at: DateTime.utc_now()
      }

      assert ClientContext.has_access_to_tag?(context, "api")
      assert ClientContext.has_access_to_tag?(context, "public")
      assert ClientContext.has_access_to_tag?(context, "coding")

      refute ClientContext.has_access_to_tag?(context, "private")
      refute ClientContext.has_access_to_tag?(context, "admin")
    end

    test "wildcard access grants access to all tags" do
      context = %ClientContext{
        allowed_tags: ["*"],
        subject: "admin-client",
        authenticated_at: DateTime.utc_now()
      }

      # Wildcard grants access to any tag
      assert ClientContext.has_access_to_tag?(context, "private")
      assert ClientContext.has_access_to_tag?(context, "admin")
      assert ClientContext.has_access_to_tag?(context, "public")
      assert ClientContext.has_access_to_tag?(context, "any-tag")

      # Wildcard grants access to any set of tags
      assert ClientContext.has_access_to_tags?(context, ["private", "admin"])
      assert ClientContext.has_access_to_tags?(context, ["public"])
      assert ClientContext.has_access_to_tags?(context, ["any", "random", "tags"])
    end

    test "wildcard works with other tags" do
      context = %ClientContext{
        allowed_tags: ["*", "public"],
        subject: "mixed-client",
        authenticated_at: DateTime.utc_now()
      }

      # Still grants access to everything due to wildcard
      assert ClientContext.has_access_to_tag?(context, "private")
      assert ClientContext.has_access_to_tag?(context, "admin")
      assert ClientContext.has_access_to_tags?(context, ["private", "admin"])
    end

    test "OR logic: access granted with partial tag match" do
      context = %ClientContext{
        allowed_tags: ["private"],
        subject: "limited-client",
        authenticated_at: DateTime.utc_now()
      }

      # Client with only "private" tag should access server with ["private", "calendars"]
      assert ClientContext.has_access_to_tags?(context, ["private", "calendars"])
      assert ClientContext.has_access_to_tags?(context, ["calendars", "private"])
      
      # But not if none of the tags match
      refute ClientContext.has_access_to_tags?(context, ["public", "calendars"])
    end

    test "generates log string representation" do
      context = %ClientContext{
        subject: "claude-code",
        allowed_tags: ["api", "public"],
        authenticated_at: DateTime.utc_now()
      }

      log_string = ClientContext.to_log_string(context)
      assert log_string == "claude-code [api, public]"
    end
  end
end