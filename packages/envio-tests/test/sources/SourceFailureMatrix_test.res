open Vitest

// How the indexer answers each way a real HyperSync source can fail, through
// the real client against a local HyperSync server. These pin today's behaviour
// before the source layer moves to Rust, so the move is checked from outside.
let port = 18791

let token = "0x1000000000000000000000000000000000000001"
let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let lastBlock = 20

let logs = Array.fromInitializer(~length=lastBlock, index => {
  let blockNumber = index + 1
  let log: ServedEvmChain.log = {
    blockNumber,
    logIndex: 0,
    address: token,
    topics: [transfer, token->ServedEvmChain.addressTopic, token->ServedEvmChain.addressTopic],
    data: blockNumber->ServedEvmChain.hex->ServedEvmChain.dropPrefix->ServedEvmChain.word,
  }
  log
})

let server: ref<option<MockHyperSyncServer.t>> = ref(None)
let getServer = () => server.contents->Option.getOrThrow
Async.beforeAll(async () => {
  let created = MockHyperSyncServer.make(~height=lastBlock, ~port)
  created->MockHyperSyncServer.serveChain(ServedEvmChain.hyperSyncChain(~logs, ~height=lastBlock))
  server := Some(created)
})
Async.afterAll(async () => server.contents->Option.forEach(MockHyperSyncServer.close))

let scenario = Scenario.make(
  ~configYaml=`
name: source-failure-matrix
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 1
    end_block: ${lastBlock->Int.toString}
    max_reorg_depth: 0
    hypersync_config:
      url: ${ServedEvmChain.url(port)}
    contracts:
      - name: Token
        address: "${token}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}\` });
});
`,
)

type seen = {id: string}

// What a run left behind that a user could see.
type outcome = {
  exited: bool,
  seen: int,
  // `from_block` of every query the server received, in order.
  queriedFrom: array<int>,
  // The source layer's lines, at every level, as (level, msg).
  sourceLines: array<(string, string)>,
  // The message the indexer stopped with, if it did.
  error: option<string>,
}

let fromBlockOf = query =>
  query
  ->JSON.Decode.object
  ->Option.flatMap(query => query->Dict.get("from_block"))
  ->Option.flatMap(JSON.Decode.float)
  ->Option.getOr(-1.)
  ->Float.toInt

let isSourceLine = msg =>
  [
    "HyperSync",
    "Unexpected issue",
    "Failed to",
    "Your ENVIO_API_TOKEN",
    "Height retrieval",
    "Source returned",
    "The RPC provider",
    "Failed getting data",
  ]->Array.some(prefix => msg->String.includes(prefix))

// Steps the virtual clock until the indexer exits, fails, or `maxSteps` run out.
let drive = async (scenario, ~takeQueriedFrom, ~stepMs=100, ~maxSteps=200) => {
  let exited = ref(false)
  let error = ref(None)
  let result = ref(None)
  await scenario->Scenario.run(
    ~yamlSources=true,
    ~onExit=() => exited := true,
    ~onError=errHandler => error := errHandler.exn->Utils.exnMessage,
    async (~indexer, ~source as _) => {
      let steps = ref(0)
      while !exited.contents && error.contents === None && steps.contents < maxSteps {
        await indexer.advanceTime(stepMs)
        // Real time: every request resolves on real local I/O.
        await Utils.delay(5)
        steps := steps.contents + 1
      }
      let rows: array<seen> = await indexer.query("Seen")
      result :=
        Some({
          exited: exited.contents,
          seen: rows->Array.length,
          queriedFrom: takeQueriedFrom(),
          sourceLines: indexer.allLogsAsJson()->Array.filterMap(line =>
            switch (line->Dict.get("level"), line->Dict.get("msg")) {
            | (Some(String(level)), Some(String(msg))) if msg->isSourceLine => Some((level, msg))
            | _ => None
            }
          ),
          error: error.contents,
        })
    },
  )
  result.contents->Option.getOrThrow
}

let runServed = async (~prepare) => {
  let served = getServer()
  let _ = served->MockHyperSyncServer.takeQueries
  served->MockHyperSyncServer.setHeight(lastBlock)
  prepare(served)
  await scenario->drive(~takeQueriedFrom=() =>
    served->MockHyperSyncServer.takeQueries->Array.map(fromBlockOf)
  )
}

describe("HyperSync failures, served", () => {
  Async.it(
    "Waits out a 429 for the reset the server names, then asks the same range again",
    async t => {
      let outcome = await runServed(
        ~prepare=served =>
          served->MockHyperSyncServer.pushRawReply({
            status: 429,
            headers: dict{"x-ratelimit-reset": "2"},
          }),
      )
      t.expect(outcome).toEqual({
        exited: true,
        seen: lastBlock,
        queriedFrom: [1, 1],
        error: None,
        sourceLines: [
          (
            "trace",
            "HyperSync source is rate-limited - not critical, the indexer will retry in 2s. For higher limits upgrade your plan at https://envio.dev/app/api-tokens.",
          ),
        ],
      })
    },
  )

  Async.it("Retries a 500 after a backoff", async t => {
    let outcome = await runServed(
      ~prepare=served => {
        // With query caching on, the client asks by query id first and uploads
        // the full query when that fails, so a single 500 never reaches the
        // indexer. The second fails the upload too.
        served->MockHyperSyncServer.pushRawReply({status: 500, body: "internal error"})
        served->MockHyperSyncServer.pushRawReply({status: 500, body: "internal error"})
      },
    )
    t.expect(outcome).toEqual({
      exited: true,
      seen: lastBlock,
      queriedFrom: [1, 1, 1],
      error: None,
      sourceLines: [
        ("trace", "Unexpected issue while fetching events from HyperSync client. Attempt a retry."),
      ],
    })
  })

  Async.it("Asks again for a page that ended where it began", async t => {
    let outcome = await runServed(
      ~prepare=served => served->MockHyperSyncServer.pushResponse({nextBlock: 1}),
    )
    t.expect(outcome).toEqual({
      exited: true,
      seen: lastBlock,
      queriedFrom: [1, 1],
      error: None,
      sourceLines: [
        (
          "trace",
          "HyperSync hasn't reached block 1 on all of its servers yet. This is normal near the latest block and resolves by itself - retrying shortly.",
        ),
      ],
    })
  })

  Async.it("Keeps the known height when a page reports none", async t => {
    let outcome = await runServed(
      ~prepare=served =>
        served->MockHyperSyncServer.pushResponse({nextBlock: 11, archiveHeight: -1}),
    )
    t.expect(outcome).toEqual({
      exited: true,
      // The pushed page scans blocks 1 to 10 and holds none of their logs.
      seen: lastBlock - 10,
      queriedFrom: [1, 11],
      error: None,
      sourceLines: [],
    })
  })

  Async.it("Gives up on the query when a page lacks a field it must carry", async t => {
    let chain = ServedEvmChain.hyperSyncChain(~logs=[logs->Array.getUnsafe(0)], ~height=1)
    let outcome = await runServed(
      ~prepare=served =>
        served->MockHyperSyncServer.pushResponse({
          nextBlock: 2,
          // The block the log lands on, without its timestamp.
          blocks: [
            JSON.Object(
              dict{
                "number": JSON.Number(1.),
                "hash": JSON.String(1->ServedEvmChain.blockHash),
              },
            ),
          ],
          logs: chain.logs,
        }),
    )
    t.expect(outcome).toEqual({
      exited: false,
      seen: 0,
      queriedFrom: [1],
      error: Some(
        "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.",
      ),
      sourceLines: [
        (
          "warn",
          "Source returned invalid data with missing required fields: block.timestamp - Attempting another source",
        ),
      ],
    })
  })

  Async.it("Says once that the API token was refused, and keeps asking", async t => {
    let refused: MockHyperSyncServer.rawReply = {status: 401, body: "401 Unauthorized"}
    let outcome = await runServed(
      ~prepare=served => {
        served->MockHyperSyncServer.pushHeightReply(refused)
        served->MockHyperSyncServer.pushHeightReply(refused)
      },
    )
    t.expect(outcome).toEqual({
      exited: true,
      seen: lastBlock,
      queriedFrom: [1],
      error: None,
      sourceLines: [
        (
          "error",
          "Your ENVIO_API_TOKEN was rejected by HyperSync (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens",
        ),
        ("trace", "Height retrieval from HyperSync source failed. Retrying in 1000ms."),
        ("trace", "Height retrieval from HyperSync source failed. Retrying in 2000ms."),
      ],
    })
  })
})

let rpcPort = 18792

// Replies to the next `eth_getLogs` requests, in order, before the chain is
// served normally.
let rpcFailures: ref<array<JSON.t => (int, string)>> = ref([])
let rpcLogsFrom: ref<array<int>> = ref([])

let rpcEnvelope = (request, field, value) => {
  let envelope = dict{
    "jsonrpc": JSON.String("2.0"),
    "id": request->JSON.Decode.object->Option.flatMap(Dict.get(_, "id"))->Option.getOr(Null),
  }
  envelope->Dict.set(field, value)
  JSON.stringify(JSON.Object(envelope))
}

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port=rpcPort, ~handler=body => {
    let request = body->JSON.parseOrThrow
    let fields = request->JSON.Decode.object->Option.getOrThrow
    let method = fields->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    let params = fields->Dict.getUnsafe("params")
    if method == "eth_getLogs" {
      let fromBlock =
        params
        ->JSON.Decode.array
        ->Option.flatMap(params => params[0])
        ->Option.flatMap(JSON.Decode.object)
        ->Option.flatMap(filter => filter->Dict.get("fromBlock"))
        ->Option.map(ServedEvmChain.quantity)
        ->Option.getOr(-1)
      rpcLogsFrom := rpcLogsFrom.contents->Array.concat([fromBlock])
    }
    let failure = method == "eth_getLogs" ? rpcFailures.contents->Array.shift : None
    switch failure {
    | Some(fail) => fail(request)
    | None => (
        200,
        request->rpcEnvelope(
          "result",
          ServedEvmChain.rpcResult(~logs, ~height=lastBlock, ~method, ~params),
        ),
      )
    }
  })
)

let rpcScenario = Scenario.make(
  ~configYaml=`
name: source-failure-matrix-rpc
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 1
    end_block: ${lastBlock->Int.toString}
    max_reorg_depth: 0
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      backoff_millis: 300
    contracts:
      - name: Token
        address: "${token}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}\` });
});
`,
)

let runRpc = async (~failures) => {
  rpcFailures := failures
  rpcLogsFrom := []
  await rpcScenario->drive(~takeQueriedFrom=() => rpcLogsFrom.contents)
}

describe("RPC failures, served", () => {
  Async.it("Waits out a throttled eth_getLogs and asks the same range again", async t => {
    let outcome = await runRpc(
      ~failures=[
        request => (
          429,
          request->rpcEnvelope(
            "error",
            JSON.Object(
              dict{"code": JSON.Number(-32005.), "message": JSON.String("limit exceeded")},
            ),
          ),
        ),
      ],
    )
    t.expect(outcome).toEqual({
      exited: true,
      seen: lastBlock,
      queriedFrom: [1, 1],
      error: None,
      sourceLines: [
        ("trace", "The RPC provider is rate limiting requests. Will retry the same block range."),
      ],
    })
  })

  Async.it("Asks a narrower range after a server error", async t => {
    let outcome = await runRpc(~failures=[_ => (500, "internal error")])
    t.expect(outcome).toEqual({
      exited: true,
      seen: lastBlock,
      // The retry asks 1 to 16, and the next page carries on from there.
      queriedFrom: [1, 1, 17],
      error: None,
      sourceLines: [
        (
          "trace",
          "Failed getting data for the block range. Will try smaller block range for the next attempt.",
        ),
      ],
    })
  })
})
