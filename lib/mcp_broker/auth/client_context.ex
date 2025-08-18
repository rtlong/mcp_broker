defmodule McpBroker.Auth.ClientContext do
  @moduledoc """
  Represents authenticated client context and permissions.
  
  Stores client authentication state including allowed tags for
  tag-based access control to MCP servers.
  """

  @type t :: %__MODULE__{
    subject: String.t(),
    allowed_tags: [String.t()],
    authenticated_at: DateTime.t()
  }

  defstruct [
    :subject,
    :allowed_tags,
    :authenticated_at
  ]

  @doc """
  Creates a new client context from JWT claims.
  """
  def from_jwt_claims(claims) do
    %__MODULE__{
      subject: Map.get(claims, "sub"),
      allowed_tags: Map.get(claims, "allowed_tags", []),
      authenticated_at: DateTime.utc_now()
    }
  end

  @doc """
  Checks if the client has access to any of the given tags.
  
  Returns true if the client's allowed_tags contains any of the required_tags.
  """
  def has_access_to_tags?(%__MODULE__{allowed_tags: allowed_tags}, required_tags) when is_list(required_tags) do
    not MapSet.disjoint?(MapSet.new(allowed_tags), MapSet.new(required_tags))
  end

  @doc """
  Checks if the client has access to a specific tag.
  """
  def has_access_to_tag?(%__MODULE__{allowed_tags: allowed_tags}, tag) when is_binary(tag) do
    tag in allowed_tags
  end

  @doc """
  Returns a string representation of the client context for logging.
  """
  def to_log_string(%__MODULE__{} = context) do
    "#{context.subject} [#{Enum.join(context.allowed_tags, ", ")}]"
  end
end