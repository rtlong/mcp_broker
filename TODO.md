# MCP Broker TODO

## Completed ✅
- [x] Create distributed server module for main broker
- [x] Update main application to support distribution  
- [x] Create client application module
- [x] Create STDIO handler for client nodes
- [x] Create startup scripts (bin/start_broker, bin/mcp_client)
- [x] Update mix.exs to support dual applications
- [x] Fix Logger output to stderr for STDIO compatibility

## Fixed Issues ✅ 
- [x] **Global name registration working** - Takes ~1 second for global names to propagate between nodes
- [x] **STDIO transport working** - Successfully processes MCP initialize request and returns proper response
- [x] **Distributed architecture functional** - Client connects to broker via Erlang distribution
- [x] **Tool registration working** - Broker now properly registers 5 tools from ical and searxng servers
- [x] **Tools/list endpoint working** - Returns proper tool descriptions and schemas
- [x] **JSON-RPC ID handling fixed** - No more null ID validation errors
- [x] **Claude Desktop compatibility** - Should now work with real MCP clients

## Current Status 🎉

**✅ DISTRIBUTED MCP BROKER IS WORKING WITH CLAUDE DESKTOP!**

Successfully tested with real Claude Desktop:
- `initialize` method ✅ - returns proper server info and capabilities
- `tools/list` method ✅ - returns 5 tools: create_event, list_calendars, list_events, search, update_event
- `tools/call` (list_calendars) ✅ - returns actual calendar data from ical server
- `notifications/*` ✅ - properly handles notifications without sending responses
- STDIO transport ✅ - maintains clean separation (JSON to stdout, logs to stderr)
- Distributed architecture ✅ - allows concurrent client connections
- Centralized permission handling ✅ - MCP servers run once in main broker

## Future Enhancements 💡

### Active Issues
- [ ] **Fix JSON escaping in tool responses** - `list_events` returns "Bad escaped character in JSON at position 1014"

### Performance & UX
- [ ] **Improve startup time** - Global name propagation takes 1+ seconds
- [ ] **Add resources/list support** - Currently returns "Method not found"
- [ ] **Add prompts/list support** - Currently returns "Method not found"

### Debug Info Needed
- Broker logs show: `Distributed server successfully registered globally as #PID<0.254.0>`
- Client shows: `Connected nodes: [:mcp_broker@localhost]` then `Connected nodes: []`
- Client shows: `Global names: []` consistently

### Test Results
```
# What we see:
Starting MCP client node: mcp_client_XXX@localhost
Started distributed node: mcp_client_XXX@localhost  
Starting STDIO handler
Connected to main broker: mcp_broker@localhost      # ✅ Initial connection works
Connected nodes: [:mcp_broker@localhost]            # ✅ Node visible initially  
Global names: []                                    # ❌ No global names visible
Connected nodes: []                                 # ❌ Connection lost
```

## Next Steps
1. Investigate why global name service isn't working between nodes
2. Debug connection stability issues
3. Verify distributed Erlang setup is correct
4. Test with proper MCP client once working