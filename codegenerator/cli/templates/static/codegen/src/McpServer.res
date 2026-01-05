// MCP (Model Context Protocol) Server for HyperIndex
// Provides tools to interact with the indexer during development

open Mcp

// Import Zod for creating schemas
module Z = {
  @module("zod/v4") @scope("z") external string: unit => 'a = "string"
  @module("zod/v4") @scope("z") external number: unit => 'a = "number"
  @module("zod/v4") @scope("z") external object: Js.Dict.t<'a> => 'a = "object"
  
  @send external optional: 'a => 'a = "optional"
  @send external describe: ('a, string) => 'a = "describe"
}

// Context needed to execute tools
type toolContext = {
  getState: unit => Js.Json.t,
  indexerConfig: Indexer.t,
}

// Helper to create error responses
let makeErrorJson = (message: string): Js.Json.t => {
  let dict = Js.Dict.empty()
  dict->Js.Dict.set("error", message->Js.Json.string)
  dict->Js.Json.object_
}

// Helper to extract arguments from request
// With inputSchema, the SDK passes arguments directly as an object
let getArg = (arguments: Js.Json.t, key: string): option<Js.Json.t> => {
  arguments
  ->Js.Json.decodeObject
  ->Belt.Option.flatMap(obj => obj->Js.Dict.get(key))
}

let getStringArg = (arguments: Js.Json.t, key: string): option<string> => {
  getArg(arguments, key)->Belt.Option.flatMap(Js.Json.decodeString)
}

let getNumberArg = (arguments: Js.Json.t, key: string): option<float> => {
  getArg(arguments, key)->Belt.Option.flatMap(Js.Json.decodeNumber)
}

// Tool implementations
let handleGetIndexerState = (arguments: Js.Json.t, context: toolContext): Promise.t<toolResult> => {
  let stateJson = context.getState()
  let chainIdFilter = getNumberArg(arguments, "chainId")

  // Filter by chainId if provided
  let filteredJson = switch (chainIdFilter, stateJson->Js.Json.decodeObject) {
  | (Some(targetChainId), Some(obj)) =>
    switch obj->Js.Dict.get("chains") {
    | Some(chainsJson) =>
      switch chainsJson->Js.Json.decodeArray {
      | Some(chains) =>
        let filtered = chains->Js.Array2.filter(chain => {
          switch chain->Js.Json.decodeObject {
          | Some(chainObj) =>
            switch chainObj->Js.Dict.get("chainId") {
            | Some(chainIdJson) =>
              switch chainIdJson->Js.Json.decodeNumber {
              | Some(chainId) => chainId == targetChainId
              | None => false
              }
            | None => false
            }
          | None => false
          }
        })
        let newObj = Js.Dict.empty()
        obj->Js.Dict.entries->Js.Array2.forEach(((key, value)) => {
          if key == "chains" {
            newObj->Js.Dict.set(key, filtered->Js.Json.array)
          } else {
            newObj->Js.Dict.set(key, value)
          }
        })
        newObj->Js.Json.object_
      | None => stateJson
      }
    | None => stateJson
    }
  | _ => stateJson
  }

  Promise.resolve({
    content: [
      {
        type_: "text",
        text: Js.Json.stringify(filteredJson),
      },
    ],
    isError: false,
  })
}



let handleGetMetrics = (_arguments: Js.Json.t, _context: toolContext): Promise.t<toolResult> => {
  // Get metrics directly from Prometheus client
  PromClient.defaultRegister
  ->PromClient.metrics
  ->Promise.then(metricsText => {
    // Parse Prometheus text format into JSON
    let lines = metricsText->Js.String2.split("\n")
    let metrics = []

    lines->Js.Array2.forEach(line => {
      let trimmed = line->Js.String2.trim
      if (
        trimmed != "" &&
        !Js.String2.startsWith(trimmed, "#") &&
        Js.String2.includes(trimmed, " ")
      ) {
        let parts = trimmed->Js.String2.split(" ")
        if parts->Js.Array2.length >= 2 {
          let name = parts->Js.Array2.unsafe_get(0)
          let value = parts->Js.Array2.unsafe_get(1)
          let _ = metrics->Js.Array2.push((name, value))
        }
      }
    })

    let metricsDict = Js.Dict.fromArray(
      metrics->Js.Array2.map(((name, value)) => (name, value->Js.Json.string)),
    )

    Promise.resolve({
      content: [
        {
          type_: "text",
          text: Js.Json.stringify(metricsDict->Js.Json.object_),
        },
      ],
      isError: false,
    })
  })
  ->Promise.catch(_error => {
    Promise.resolve({
      content: [
        {
          type_: "text",
          text: Js.Json.stringify(makeErrorJson("Failed to get metrics")),
        },
      ],
      isError: true,
    })
  })
}

let handleGetConfig = (_arguments: Js.Json.t, context: toolContext): Promise.t<toolResult> => {
  // Build a simplified config object
  let configDict = Js.Dict.empty()

  // Add chain configs
  let chainConfigs =
    context.indexerConfig.config.chainMap
    ->ChainMap.values
    ->Js.Array2.map(chainConfig => {
      let chainDict = Js.Dict.empty()
      chainDict->Js.Dict.set("chainId", chainConfig.id->Belt.Int.toFloat->Js.Json.number)
      chainDict->Js.Dict.set("startBlock", chainConfig.startBlock->Belt.Int.toFloat->Js.Json.number)
      chainDict->Js.Dict.set(
        "endBlock",
        chainConfig.endBlock
        ->Belt.Option.map(Belt.Int.toFloat)
        ->Belt.Option.map(Js.Json.number)
        ->Belt.Option.getWithDefault(Js.Json.null),
      )
      chainDict->Js.Json.object_
    })

  configDict->Js.Dict.set("chains", chainConfigs->Js.Json.array)
  configDict->Js.Dict.set(
    "shouldRollbackOnReorg",
    context.indexerConfig.config.shouldRollbackOnReorg->Js.Json.boolean,
  )

  Promise.resolve({
    content: [
      {
        type_: "text",
        text: Js.Json.stringify(configDict->Js.Json.object_),
      },
    ],
    isError: false,
  })
}

let handleDumpEffectCache = (_arguments: Js.Json.t, context: toolContext): Promise.t<toolResult> => {
  // Call the existing dumpEffectCache method
  let storage = context.indexerConfig.persistence->Persistence.getInitializedStorageOrThrow
  
  storage.dumpEffectCache()
  ->Promise.then(() => {
    let resultDict = Js.Dict.empty()
    resultDict->Js.Dict.set("success", true->Js.Json.boolean)
    resultDict->Js.Dict.set("message", "Effect cache dumped to .envio/cache directory"->Js.Json.string)
    resultDict->Js.Dict.set("cachePath", ".envio/cache"->Js.Json.string)
    
    Promise.resolve({
      content: [
        {
          type_: "text",
          text: Js.Json.stringify(resultDict->Js.Json.object_),
        },
      ],
      isError: false,
    })
  })
  ->Promise.catch(error => {
    let errorMessage = switch error->Js.Exn.asJsExn {
    | Some(exn) => 
      switch Js.Exn.message(exn) {
      | Some(msg) => msg
      | None => "Unknown error occurred while dumping effect cache"
      }
    | None => "Unknown error occurred while dumping effect cache"
    }
    
    Promise.resolve({
      content: [
        {
          type_: "text",
          text: Js.Json.stringify(makeErrorJson(errorMessage)),
        },
      ],
      isError: true,
    })
  })
}

// Helper to create inputSchema with Zod object schema
let makeInputSchema = (fields: array<(string, 'a)>): 'a => {
  let dict = Js.Dict.empty()
  fields->Js.Array2.forEach(((key, value)) => {
    dict->Js.Dict.set(key, value)
  })
  Z.object(dict)
}

// Create and configure MCP server  
let createServer = (~context: toolContext): mcpServer => {
  let server = createMcpServer({
    "name": "hyperindex-mcp",
    "version": "0.1.0",
  })

  // Register get_indexer_state tool
  server->registerTool(
    "get_indexer_state",
    {
      description: "Get current indexer sync state including block heights, progress, and chain information",
      inputSchema: Some(makeInputSchema([
        ("chainId", Z.number()->Z.optional->Z.describe("Optional chain ID to filter by")),
      ])),
    },
    args => handleGetIndexerState(args, context),
  )

  // Register get_metrics tool
  server->registerTool(
    "get_metrics",
    {
      description: "Get indexer performance metrics in JSON format (events processed, sync speed, etc.)",
    },
    args => handleGetMetrics(args, context),
  )

  // Register get_config tool
  server->registerTool(
    "get_config",
    {
      description: "Get indexer runtime configuration including networks, contracts, and settings",
    },
    args => handleGetConfig(args, context),
  )

  // Register dump_effect_cache tool
  server->registerTool(
    "dump_effect_cache",
    {
      description: "Export effect cache to disk (.envio/cache directory). Effects cache RPC calls and external data fetches for performance.",
    },
    args => handleDumpEffectCache(args, context),
  )

  server
}
