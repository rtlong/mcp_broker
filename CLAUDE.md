# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Elixir project implementing a distributed MCP (Model Context Protocol) broker using the Hermes MCP library and Erlang distribution. The broker uses a distributed architecture with:

- **Main Broker Node**: Manages MCP server connections, handles permissions, and aggregates tools
- **Client Nodes**: Lightweight BEAM processes that provide STDIO interfaces to external clients
- **Erlang Distribution**: Native inter-node communication between client nodes and main broker

This design allows multiple concurrent STDIO clients while running MCP servers only once in the main broker (crucial for macOS permission handling).

## Key Commands

### Development

- `mix deps.get` - Install dependencies
- `mix compile` - Compile the project
- `mix test` - Run all tests
- `mix test test/specific_test.exs` - Run a specific test file
- `iex -S mix` - Start interactive Elixir shell with project loaded

### Common Mix Tasks

- `mix format` - Format code according to Elixir standards
- `mix credo` - Run code analysis (if credo is added)
- `mix dialyzer` - Run static analysis (if dialyzer is added)
- `mix deps.update --all` - Update all dependencies

## Architecture

The project follows standard Elixir/OTP patterns:

### Core Modules

#### Main Broker Node

- `McpBroker` - Main module with basic functionality
- `McpBroker.DistributedServer` - Handles calls from distributed client nodes
- `McpBroker.Server` - Dynamic MCP server that exposes aggregated tools
- `McpBroker.ClientManager` - Manages multiple MCP client connections
- `McpBroker.ToolAggregator` - Aggregates tools from all clients with conflict resolution
- `McpBroker.Config` - Configuration loading and validation

#### Client Node

- `McpClient.Application` - Lightweight application for STDIO client nodes
- `McpClient.StdioHandler` - Handles STDIO communication and proxies to distributed broker

### Distributed MCP Implementation

The broker uses Erlang distribution and the Hermes MCP library:

- **Main Broker**: `McpBroker.Server` implements Hermes.Server behavior with dynamic tool registration
- **Client Nodes**: Lightweight BEAM processes that proxy STDIO to the main broker via Erlang distribution
- **MCP Servers**: Run only in the main broker node, handling permissions once
- **Tool Aggregation**: Tools from multiple clients are aggregated and name conflicts are resolved automatically
- **Distribution**: Uses `:global` process registry for broker discovery and GenServer calls for RPC

### Configuration

The broker reads configuration from XDG standard paths or fallback locations:

1. `$XDG_CONFIG_HOME/mcp_broker/config.json` (if `XDG_CONFIG_HOME` is set)
2. `~/.config/mcp_broker/config.json` (standard XDG location)
3. `config.json` (current directory fallback)
4. Custom path via `MCP_CONFIG_PATH` environment variable (overrides all above)

```json
{ 
  "mcpServers": {
    "ical": {
      "tags": ["filesystem"],
      "command": "uvx",
      "args": ["mcp-server-filesystem", "/tmp"],
      "env": {
        "PATH": "/bin:/usr/local/bin"
      }
    }
  }
}
```

### Usage

#### Standard Usage

Start the main broker and connect clients via STDIO:

```bash
# Start the main broker (uses XDG config paths by default)
bin/start_broker

# In separate terminals, start STDIO clients
bin/mcp_client

# Custom config file for broker
MCP_CONFIG_PATH=/path/to/config.json bin/start_broker

# Client authentication via environment variable
MCP_CLIENT_JWT="your-jwt-token" bin/mcp_client
```

#### Development Usage

```bash
# Interactive shell with the broker running
iex -S mix

# Compile and run
mix compile && mix run --no-halt

# Run tests
mix test
```

The distributed broker automatically:

1. **Main Broker**: Reads MCP server configuration from config.json
2. **Main Broker**: Connects to all configured servers as clients (handling permissions)
3. **Main Broker**: Aggregates their tools with automatic name conflict resolution
4. **Main Broker**: Registers globally for distributed client access
5. **Client Nodes**: Start with unique node names and connect to main broker
6. **Client Nodes**: Handle STDIO communication with external MCP clients
7. **Client Nodes**: Proxy MCP calls to main broker via Erlang distribution

### Dependencies

- `hermes_mcp ~> 0.14.0` - Core MCP implementation library
- Standard Elixir applications: logger

## Project Structure

```
mcp_broker/
├── lib/
│   ├── mcp_broker.ex           # Main module
│   ├── mcp_broker/             # Main broker implementation
│   │   ├── application.ex      # Enhanced with distribution
│   │   ├── distributed_server.ex  # Handles distributed calls
│   │   ├── server.ex           # MCP server implementation
│   │   ├── client_manager.ex   # Manages MCP client connections
│   │   └── tool_aggregator.ex  # Tool aggregation logic
│   └── mcp_client/             # Lightweight client app
│       ├── application.ex      # Client node application
│       └── stdio_handler.ex    # STDIO communication handler
├── bin/
│   ├── start_broker           # Start main broker script
│   └── mcp_client            # Client launcher script
├── test/                      # Test files using ExUnit
└── mix.exs                   # Project configuration
```

## Testing

Uses ExUnit as the testing framework. Tests include doctests for documentation examples.
