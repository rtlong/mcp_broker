
# Tag-Based Access Control with JWT Authentication Plan

## Overview

Implement a fine-grained access control system for the MCP broker that uses server tags and JWT-based client authentication to control which tools each client can access.

## Core Requirements Analysis

1. **Tag-based server filtering**: Use existing `tags` configuration to group servers by purpose (e.g., `["calendar", "personal"]`, `["api", "public"]`)
2. **JWT authentication**: Stateless authentication using signed tokens containing allowed tags
3. **No credential database**: Self-contained JWT tokens eliminate need for credential storage
4. **Per-client access control**: Different AI clients get different tool sets based on their JWT claims

## Architecture Components

### 1. JWT Token Structure

```json
{
  "iss": "mcp-broker",
  "sub": "claude-code", 
  "aud": "mcp-broker",
  "exp": 1735689600,
  "iat": 1704067200,
  "allowed_tags": ["api", "public", "coding"],
  "client_name": "Claude Code",
  "client_type": "ide"
}
```

### 2. Authentication Flow

```
Client Startup → Load JWT from config → Connect to broker → 
Authenticate with JWT → Get filtered tool list → Make tool calls
```

### 3. Modified Communication Protocol

- Add authentication step to distributed server protocol
- Include JWT in initial client connection
- Store authenticated client context in distributed server state
- Filter tools based on client's allowed tags before responding

## Implementation Plan

### Phase 1: JWT Infrastructure

1. **Add Joken dependency** to `mix.exs`
2. **Create JWT module** (`McpBroker.Auth.JWT`)
   - Token generation utilities for admin use
   - Token verification with claims validation
   - Support for RSA256 signing (secure for production)
   - Custom claim validation for `allowed_tags`

3. **Create CLI tool** for JWT generation
   - `bin/generate_jwt` script for creating client tokens
   - Interactive prompts for client name, allowed tags, expiration
   - Output ready-to-use JWT strings

### Phase 2: Authentication Integration

4. **Modify distributed server** (`McpBroker.DistributedServer`)
   - Add authentication state to GenServer state
   - New `{:authenticate, jwt}` message handler
   - Store per-client allowed tags after successful auth
   - Reject unauthenticated clients after grace period

5. **Update STDIO handler** (`McpClient.StdioHandler`)
   - Load JWT from environment variable or config file
   - Send authentication message on broker connection
   - Handle authentication failure gracefully
   - Include JWT in error logs for debugging

### Phase 3: Tag-Based Filtering

6. **Enhance tool aggregator** (`McpBroker.ToolAggregator`)
   - Add `filter_tools_by_tags/2` function
   - Modify `aggregate_tools/1` to accept allowed tags parameter
   - Server tag lookup from configuration
   - Tool filtering logic: include tool if server has ANY allowed tag

7. **Update distributed server handlers**
   - Modify `tools/list` to filter by client's allowed tags
   - Modify `tools/call` to verify client can access target tool
   - Return appropriate errors for unauthorized tool access

### Phase 4: Configuration & UX

8. **Environment configuration**
   - `MCP_CLIENT_JWT` environment variable for token
   - Optional config file support (`~/.mcp/client.json`)
   - Graceful fallback for development (warn but allow all)

9. **Enhanced startup scripts**
   - Update `bin/mcp_client` to load JWT from config
   - Add validation and helpful error messages
   - Document JWT configuration in startup logs

## Security Considerations

### JWT Security

- **RSA256 signing**: Use asymmetric keys (private for signing, public for verification)
- **Token expiration**: Reasonable expiry times (e.g., 30-90 days)
- **Claim validation**: Verify issuer, audience, and custom claims
- **Key management**: Store private key securely, embed public key in broker

### Access Control

- **Fail-safe defaults**: Reject unauthenticated clients
- **Principle of least privilege**: Clients only see tools they're authorized for
- **Audit logging**: Log authentication attempts and tool access
- **Tag inheritance**: Server with multiple tags accessible to clients with ANY matching tag

## Configuration Examples

### Server Configuration (existing, enhanced)

```json
{
  "mcpServers": {
    "ical": {
      "tags": ["calendar", "personal"],
      "type": "stdio",
      "command": "...",
      "args": ["..."]
    },
    "github": {
      "tags": ["coding", "api", "public"],
      "type": "stdio", 
      "command": "...",
      "args": ["..."]
    }
  }
}
```

### Client Configuration (new)

```json
{
  "jwt": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "client_name": "Claude Code"
}
```

## Implementation Files

### New Files

- `lib/mcp_broker/auth/jwt.ex` - JWT handling module
- `lib/mcp_broker/auth/client_context.ex` - Client authentication state
- `bin/generate_jwt` - JWT generation utility
- `config/jwt_keys/` - RSA key pair storage

### Modified Files  

- `mix.exs` - Add Joken dependency
- `lib/mcp_broker/distributed_server.ex` - Authentication integration
- `lib/mcp_broker/tool_aggregator.ex` - Tag-based filtering
- `lib/mcp_client/stdio_handler.ex` - JWT authentication
- `lib/mcp_client/application.ex` - JWT configuration loading
- `bin/mcp_client` - Enhanced startup with JWT support

## Testing Strategy

- Unit tests for JWT generation/verification
- Integration tests for tag-based filtering
- End-to-end tests with multiple client configurations
- Security tests for invalid/expired tokens
- Performance tests for large numbers of servers/tags

## Migration Path

1. **Backwards compatibility**: Run in permissive mode initially
2. **Gradual rollout**: Warning phase before enforcement
3. **Development mode**: Allow unauthenticated access with warnings
4. **Production mode**: Strict authentication required

This plan provides a comprehensive, secure, and scalable solution for tag-based access control while maintaining the existing distributed architecture and adding minimal complexity to the client setup process.
