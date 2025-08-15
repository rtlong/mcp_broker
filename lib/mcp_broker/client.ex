defmodule McpBroker.Client do
  use Hermes.Client,
    name: "McpBroker",
    version: McpBroker.MixProject.project()[:version],
    protocol_version: "2024-11-05",
    capabilities: [:roots]
end
