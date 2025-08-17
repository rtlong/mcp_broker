# MCP Broker

A distributed Model Context Protocol (MCP) broker that aggregates multiple MCP servers and provides concurrent STDIO access from multiple clients.

## Features

- **Distributed Architecture**: Single main broker with lightweight STDIO client nodes
- **Concurrent STDIO Access**: Multiple clients can connect simultaneously via STDIO
- **Dynamic Configuration**: Read MCP server configurations from JSON
- **Tool Aggregation**: Automatically collect and expose tools from all configured servers
- **Name Conflict Resolution**: Automatically prefix conflicting tool names
- **Centralized Permissions**: MCP servers run once in main broker (important for macOS permissions)
- **Fault Isolation**: Client crashes don't affect broker or other clients

## Quick Start

1. **Configure your MCP servers** in `config.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "uvx",
      "args": ["mcp-server-filesystem", "/tmp"],
      "tags": ["file-operations"]
    },
    "ical": {
      "type": "stdio",
      "command": "uvx", 
      "args": ["mcp-server-ical"],
      "tags": ["calendar"]
    }
  }
}
```

1. **Start the main broker**:

```bash
bin/start_broker
```

1. **Connect clients via STDIO**:

```bash
# Terminal 1: Claude Desktop (or other MCP client)
bin/mcp_client

# Terminal 2: Another client
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

## Configuration

### Environment Variables

- `MCP_CONFIG_PATH`: Path to config file (default: `config.json`)

### Examples

```bash
# Use different config file
MCP_CONFIG_PATH=production.json bin/start_broker

# Start additional clients
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
