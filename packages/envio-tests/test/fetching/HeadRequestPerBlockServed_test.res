open Vitest

// At the head against real sources: each new block is asked for once. Over
// HyperSync that is one query whose body stays the same from block to block,
// so the server's query cache keeps answering it. Over RPC the contracts
// fetched by address share one eth_getLogs, and a provider refusing that call
// as too large gets one call per contract for the same block instead.
let hyperSyncPort = 18801
let rpcPort = 18802

let token = "0x1000000000000000000000000000000000000001"
let pool = "0x2000000000000000000000000000000000000002"
let wild = "0x3000000000000000000000000000000000000003"

let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let swap = "0x3ebfdaaf4031bec9a2b7b0a1c594d2d03f3d0b8d68531c9164c2829bac00fefa"
// keccak256("Ping()")
let ping = "0xca6e822df923f741dfe968d15d80a18abd25bd1e748bcb9ad81fea5bbb7386af"

let backfillHead = 300
let lastBlock = 303

let logsAt = blockNumber => [
  {
    ServedEvmChain.blockNumber,
    logIndex: 0,
    address: token,
    topics: [transfer, token->ServedEvmChain.addressTopic, pool->ServedEvmChain.addressTopic],
    data: 1->ServedEvmChain.hex->ServedEvmChain.dropPrefix->ServedEvmChain.word,
  },
  {
    ServedEvmChain.blockNumber,
    logIndex: 1,
    address: pool,
    topics: [swap],
  },
  {
    ServedEvmChain.blockNumber,
    logIndex: 2,
    address: wild,
    topics: [ping],
  },
]
let logs = [2, 301, 302, 303]->Array.flatMap(logsAt)

let schema = `
type Seen {
  id: ID!
}
`

let handlers = (~wildcard) =>
  `
import { indexer } from "envio";

const seen = async ({ event, context }: any) =>
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}\` });
indexer.onEvent({ contract: "Token", event: "Transfer" }, seen);
indexer.onEvent({ contract: "Pool", event: "Swap" }, seen);
` ++ (
    wildcard
      ? `indexer.onEvent({ contract: "Wild", event: "Ping", wildcard: true }, seen);
indexer.onBlock({ name: "headers", fields: { block: ["timestamp"] } }, async () => {});
`
      : ""
  )

let configYaml = (~name, ~source, ~wildcard) =>
  `
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: Pool
    events:
      - event: Swap()
  - name: Wild
    events:
      - event: Ping()
chains:
  - id: 1337${source}
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "${token}"
      - name: Pool
        address: "${pool}"` ++ (
    wildcard
      ? `
      - name: Wild`
      : ""
  )

type seen = {id: string}

let seenIds = async (indexer: IndexerRunner.t) => {
  let rows: array<seen> = await indexer.query("Seen")
  rows->Array.map(row => row.id)
}

let waitForSeen = async (indexer, id) => {
  let deadline = Date.now() +. 10_000.
  // Real time: the indexer reads a local server over real I/O.
  while !((await indexer->seenIds)->Array.includes(id)) {
    if Date.now() > deadline {
      JsError.throwWithMessage(`Timed out waiting for ${id} to be indexed`)
    }
    await Utils.delay(10)
  }
}

let hyperSync: ref<option<MockHyperSyncServer.t>> = ref(None)
Async.beforeAll(async () => {
  let server = MockHyperSyncServer.make(~height=backfillHead, ~port=hyperSyncPort)
  server->MockHyperSyncServer.serveChain(ServedEvmChain.hyperSyncChain(~logs, ~height=lastBlock))
  hyperSync := Some(server)
})
Async.afterAll(async () => hyperSync.contents->Option.forEach(MockHyperSyncServer.close))
let hyperSyncServer = () =>
  hyperSync.contents->Option.getOrThrow(~message="the HyperSync server was never started")

let withoutRange = (query: JSON.t) => {
  let body = query->JSON.Decode.object->Option.getOrThrow->Dict.copy
  body->Dict.delete("from_block")
  body->Dict.delete("to_block")
  JSON.Object(body)
}

let fromBlockOf = (query: JSON.t) =>
  query
  ->JSON.Decode.object
  ->Option.getOrThrow
  ->Dict.getUnsafe("from_block")
  ->JSON.Decode.float
  ->Option.getOrThrow
  ->Float.toInt

let rpcHeight = ref(backfillHead)
// The block whose grouped by-address eth_getLogs the provider refuses as too large.
let refuseGroupedAt = 302
// Every eth_getLogs the provider was asked at the head, as `block addresses outcome`.
let headGetLogsCalls: array<string> = []

let envelope = (request, field, value) =>
  JSON.stringify(
    JSON.Object(
      Dict.fromArray([
        ("jsonrpc", JSON.String("2.0")),
        ("id", request->Dict.getUnsafe("id")),
        (field, value),
      ]),
    ),
  )

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port=rpcPort, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let params = request->Dict.getUnsafe("params")
    switch request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow {
    | "eth_getLogs" =>
      let filter =
        params
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      let addresses = (filter->ServedEvmChain.logFilter).address
      let fromBlock = filter->Dict.get("fromBlock")->Option.map(ServedEvmChain.quantity)
      let refused = fromBlock == Some(refuseGroupedAt) && addresses->Array.length > 1
      switch fromBlock {
      | Some(fromBlock) if fromBlock > backfillHead =>
        headGetLogsCalls
        ->Array.push(
          `${fromBlock->Int.toString} ${addresses->Array.join(",")} ${refused ? "refused" : "ok"}`,
        )
        ->ignore
      | _ => ()
      }
      (
        200,
        refused
          ? envelope(
              request,
              "error",
              JSON.Object(
                dict{
                  "code": JSON.Number(-32005.),
                  "message": JSON.String("query returned more than 10000 results"),
                },
              ),
            )
          : envelope(
              request,
              "result",
              JSON.Array(
                logs
                ->Array.filter(log => ServedEvmChain.rpcFilterMatches(filter, log))
                ->Array.map(ServedEvmChain.rpcLog),
              ),
            ),
      )
    | method => (
        200,
        envelope(
          request,
          "result",
          ServedEvmChain.rpcResult(~logs, ~height=rpcHeight.contents, ~method, ~params),
        ),
      )
    }
  })
)

describe("A chain at the head against real sources", () => {
  let hyperSyncScenario = Scenario.make(
    ~configYaml=configYaml(
      ~name="head-request-per-block-hypersync",
      ~source=`
    hypersync_config:
      url: ${ServedEvmChain.url(hyperSyncPort)}`,
      ~wildcard=true,
    ),
    ~schema,
    ~handlers=handlers(~wildcard=true),
  )

  Async.it("asks HyperSync for each new block in one query of the same body", async t => {
    await hyperSyncScenario->Scenario.run(
      ~yamlSources=true,
      // A real HyperSync source against a local server: its queries resolve on real I/O.
      ~virtualTime=false,
      async (~indexer, ~source as _) => {
        await indexer->waitForSeen("2-2")
        await indexer.waitUntilReady()
        let _ = hyperSyncServer()->MockHyperSyncServer.takeQueries

        for height in backfillHead + 1 to lastBlock {
          hyperSyncServer()->MockHyperSyncServer.setHeight(height)
          await indexer->waitForSeen(`${height->Int.toString}-2`)
        }
        let queries = hyperSyncServer()->MockHyperSyncServer.takeQueries
        let bodies = queries->Array.map(withoutRange)

        t.expect((
          queries->Array.map(fromBlockOf),
          bodies->Array.every(body => body == bodies->Array.getUnsafe(0)),
        )).toEqual(([301, 302, 303], true))
      },
    )
  })

  let rpcScenario = Scenario.make(
    ~configYaml=configYaml(
      ~name="head-request-per-block-rpc",
      ~source=`
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      polling_interval: 10`,
      ~wildcard=false,
    ),
    ~schema,
    ~handlers=handlers(~wildcard=false),
  )

  Async.it(
    "asks RPC for each new block in one eth_getLogs for both contracts, one per contract when refused",
    async t => {
      await rpcScenario->Scenario.run(
        ~yamlSources=true,
        // A real RPC source against a local server: its requests resolve on real I/O.
        ~virtualTime=false,
        async (~indexer, ~source as _) => {
          await indexer->waitForSeen("2-1")
          await indexer.waitUntilReady()
          for height in backfillHead + 1 to lastBlock {
            rpcHeight := height
            await indexer->waitForSeen(`${height->Int.toString}-0`)
            await indexer->waitForSeen(`${height->Int.toString}-1`)
          }
          let both = [token, pool]->Array.join(",")
          t.expect(headGetLogsCalls->Array.toSorted(String.compare)).toEqual([
            `301 ${both} ok`,
            `302 ${token} ok`,
            `302 ${both} refused`,
            `302 ${pool} ok`,
            `303 ${both} ok`,
          ])
        },
      )
    },
  )
})
