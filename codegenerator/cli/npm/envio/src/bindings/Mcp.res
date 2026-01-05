// ReScript bindings for @modelcontextprotocol/sdk v1.25.1

type mcpServer

type textContent = {
  @as("type") type_: string,
  text: string,
}

type toolResult = {
  content: array<textContent>,
  isError?: bool,
}

// Tool config for registerTool
type toolConfig<'a> = {
  title?: string,
  description?: string,
  inputSchema?: 'a, // Can be Zod schema object or raw shape
  outputSchema?: 'a,
}

// Tool callback receives parsed arguments
type toolCallback = Js.Json.t => Promise.t<toolResult>

// McpServer creation - v1 uses McpServer class from server/mcp.js
@module("@modelcontextprotocol/sdk/server/mcp.js") @new
external createMcpServer: {
  "name": string,
  "version": string,
} => mcpServer = "McpServer"

// Register a tool - takes name, config, callback
@send
external registerTool: (mcpServer, string, toolConfig<'a>, toolCallback) => unit = "registerTool"

// Check if connected
@send
external isConnected: mcpServer => bool = "isConnected"

// Transport
type streamableHttpServerTransport

// Event store interface for resumability support
type eventStore<'streamId, 'eventId> = {
  storeEvent: ('streamId, Js.Json.t) => Promise.t<'eventId>,
  getStreamIdForEventId?: 'eventId => Promise.t<option<'streamId>>,
  replayEventsAfter: ('eventId, {"send": ('eventId, Js.Json.t) => Promise.t<unit>}) => Promise.t<'streamId>,
}

// Transport options for StreamableHTTPServerTransport
// Based on WebStandardStreamableHTTPServerTransportOptions from @modelcontextprotocol/sdk v1.25.1
type streamableHttpServerTransportOptions = {
  sessionIdGenerator?: unit => string,
  onsessioninitialized?: string => Promise.t<unit>,
  onsessionclosed?: string => Promise.t<unit>,
  enableJsonResponse?: bool,
  eventStore?: eventStore<string, string>,
  allowedHosts?: array<string>,
  allowedOrigins?: array<string>,
  enableDnsRebindingProtection?: bool,
  retryInterval?: int,
}

@module("@modelcontextprotocol/sdk/server/streamableHttp.js") @new
external createStreamableHttpServerTransport: streamableHttpServerTransportOptions => streamableHttpServerTransport = "StreamableHTTPServerTransport"

// Connect server to transport
@send
external connect: (mcpServer, streamableHttpServerTransport) => Promise.t<unit> = "connect"

// Handle HTTP request
@send
external handleRequest: (streamableHttpServerTransport, 'req, 'res) => Promise.t<unit> = "handleRequest"
