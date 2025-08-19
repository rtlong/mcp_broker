# MCP Broker

A distributed Model Context Protocol (MCP) broker that aggregates multiple MCP servers and provides concurrent STDIO access from multiple clients.

## Features

- **Distributed Architecture**: Single main broker with lightweight STDIO client nodes
- **Concurrent STDIO Access**: Multiple clients can connect simultaneously via STDIO
- **JWT Authentication**: Secure client authentication with RSA256-signed tokens
- **Tag-Based Access Control**: Fine-grained permission system using server tags
- **Dynamic Configuration**: Read MCP server configurations from JSON
- **Tool Aggregation**: Automatically collect and expose tools from all configured servers
- **Name Conflict Resolution**: Automatically prefix conflicting tool names
- **Centralized Permissions**: MCP servers run once in main broker (important for macOS permissions)
- **Fault Isolation**: Client crashes don't affect broker or other clients
- **Development Mode**: Graceful fallback for development without authentication

## Quick Start

1. **Configure your MCP servers** in your config file (see Configuration section for paths):

```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "uvx",
      "args": ["mcp-server-filesystem", "/tmp"],
      "tags": ["file-operations", "public"]
    },
    "ical": {
      "type": "stdio",
      "command": "uvx", 
      "args": ["mcp-server-ical"],
      "tags": ["calendar", "personal"]
    },
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["@modelcontextprotocol/server-github"],
      "tags": ["api", "coding", "public"]
    }
  }
}
```

2. **Start the main broker**:

```bash
bin/start_broker
```

3. **Generate JWT tokens for clients** (optional, for production):

```bash
# Generate token for Claude Code with access to API and public tools
bin/generate_jwt claude-code "api,public,coding"

# Generate token for web client with limited access
bin/generate_jwt web-client "public"
```

4. **Connect clients via STDIO**:

```bash
# Development mode (no authentication required)
bin/mcp_client

# Production mode with JWT token
MCP_CLIENT_JWT="your-jwt-token-here" bin/mcp_client

# Or create a config file at ~/.mcp_broker/client.json:
# {"jwt": "your-jwt-token-here"}
bin/mcp_client
```

## Architecture

The distributed architecture separates the main broker (which manages MCP server connections and permissions) from lightweight client nodes that handle STDIO communication:

```text
External Clients        Client Nodes           Main Broker Node
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│ Claude Desktop  │────│ mcp_client_1@    │────│ mcp_broker@         │
│                 │    │ localhost        │    │ localhost           │
└─────────────────┘    └──────────────────┘    │                     │
                                               │ ┌─────────────────┐ │
┌─────────────────┐    ┌──────────────────┐    │ │ Filesystem      │ │
│ Continue.dev    │────│ mcp_client_2@    │────│ │ Server          │ │
│                 │    │ localhost        │    │ └─────────────────┘ │
└─────────────────┘    └──────────────────┘    │                     │
                                               │ ┌─────────────────┐ │
┌─────────────────┐    ┌──────────────────┐    │ │ Calendar        │ │
│ Other Client    │────│ mcp_client_N@    │────│ │ Server          │ │
│                 │    │ localhost        │    │ └─────────────────┘ │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
    STDIO                Erlang Distribution       MCP Connections
```

### Benefits

- **Single Permission Point**: MCP servers (like ical) run once in main broker, handling macOS permissions properly
- **Native STDIO**: Each client gets a real STDIO interface, no HTTP needed
- **Fault Isolation**: Client crashes don't affect broker or other clients  
- **Elixir Native**: Uses built-in Erlang distribution, no custom protocols
- **Resource Efficient**: Client nodes are lightweight, broker does heavy lifting

## Authentication & Access Control

The MCP Broker supports JWT-based authentication with tag-based access control for fine-grained permissions.

### How It Works

1. **Server Tags**: Each MCP server is configured with tags (e.g., `["api", "public", "personal"]`)
2. **Client Authentication**: Clients authenticate with JWT tokens containing allowed tags
3. **Tool Filtering**: Clients only see tools from servers whose tags they're authorized to access
4. **Access Control**: Tool calls are verified against client permissions

### JWT Token Management

#### Generating Tokens

```bash
# Generate a token for a client
bin/generate_jwt SUBJECT TAGS

# Examples:
bin/generate_jwt claude-code "api,public,coding"
bin/generate_jwt cursor "api,coding"
bin/generate_jwt web-app "public"
```

#### Token Configuration

Clients can provide JWT tokens via:

1. **Environment Variable**: `MCP_CLIENT_JWT="your-token-here"`
2. **Config File**: Create `~/.mcp/client.json` with `{"jwt": "your-token-here"}`
3. **Development Mode**: No token required (all access granted with warnings)

### Access Control Examples

```json
{
  "mcpServers": {
    "public-api": {
      "tags": ["public", "api"],
      "command": "npx", 
      "args": ["@modelcontextprotocol/server-everything"]
    },
    "personal-calendar": {
      "tags": ["personal", "calendar"],
      "command": "uvx",
      "args": ["mcp-server-ical"]
    },
    "development-tools": {
      "tags": ["coding", "dev"],
      "command": "npx",
      "args": ["@modelcontextprotocol/server-github"]
    }
  }
}
```

**Client Access Examples:**

- JWT with `["public"]` → Can only access `public-api` server
- JWT with `["personal", "calendar"]` → Can only access `personal-calendar` server  
- JWT with `["public", "coding"]` → Can access `public-api` and `development-tools`
- No JWT (dev mode) → Can access all servers with warnings

### Security Features

- **RSA256 Signing**: Tokens use asymmetric cryptography for security
- **Expiration**: Tokens automatically expire (default: 30 days)
- **Fail-Safe Defaults**: Unknown clients are denied access
- **Audit Logging**: Authentication attempts and tool access are logged
- **Development Mode**: Graceful fallback for local development

## Configuration

### Config File Location

The broker reads configuration from XDG standard paths or fallback locations:

1. `$XDG_CONFIG_HOME/mcp_broker/config.json` (if `XDG_CONFIG_HOME` is set)
2. `~/.config/mcp_broker/config.json` (standard XDG location)
3. `config.json` (current directory fallback)
4. Custom path via `MCP_CONFIG_PATH` environment variable (overrides all above)

### Environment Variables

- `MCP_CONFIG_PATH`: Custom path to config file (overrides XDG paths)
- `MCP_CLIENT_JWT`: JWT token for client authentication

### Examples

```bash
# Use different config file
MCP_CONFIG_PATH=production.json bin/start_broker

# Start authenticated client
MCP_CLIENT_JWT="eyJhbGciOiJSUzI1NiIs..." bin/mcp_client

# Development mode (no auth)
bin/mcp_client
```

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Start in development mode
iex -S mix

# Format code
mix format
```

## License

MIT
