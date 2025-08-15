# MCP Broker

A dynamic Model Context Protocol (MCP) broker that aggregates multiple MCP servers into a single unified interface.

## Features

- **Dynamic Configuration**: Read MCP server configurations from JSON
- **Multiple Transports**: Support for HTTP, WebSocket, SSE, and STDIO
- **Tool Aggregation**: Automatically collect and expose tools from all configured servers
- **Name Conflict Resolution**: Automatically prefix conflicting tool names
- **Hot Reloading**: Restart to pick up configuration changes

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
    "git": {
      "type": "stdio", 
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "."],
      "tags": ["version-control"]
    }
  }
}
```

2. **Start the broker**:

```bash
mix run --no-halt
```

The broker will start on `http://localhost:4567` by default.

## Configuration

### Environment Variables

- `MCP_CONFIG_PATH`: Path to config file (default: `config.json`)
- `MCP_TRANSPORT`: Transport type (default: `streamable_http`)

### Transport Options

- `streamable_http`: HTTP server on port 4567 (default)
- `stdio`: Standard input/output
- `sse`: Server-sent events on port 4567
- `websocket`: WebSocket transport

### Examples

```bash
# Use different config file
MCP_CONFIG_PATH=production.json mix run --no-halt

# Use STDIO transport
MCP_TRANSPORT=stdio mix run --no-halt

# Use SSE transport
MCP_TRANSPORT=sse mix run --no-halt
```

## Architecture

The broker acts as both an MCP client (connecting to downstream servers) and an MCP server (exposing aggregated tools):

```
MCP Client → MCP Broker → Multiple MCP Servers
             (Port 4567)   (filesystem, git, etc.)
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

