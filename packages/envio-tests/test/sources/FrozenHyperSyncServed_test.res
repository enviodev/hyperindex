open Vitest

// https://github.com/enviodev/hyperindex/issues/1829
// A HyperSync instance that stopped following its chain, with an RPC fallback
// that keeps up, both real sources against local servers. HyperSync answers a
// query past its height with a page that ends where it began, which the source
// reads as being behind the head.
let hyperSyncPort = 18761
let rpcPort = 18762

let token = "0x1000000000000000000000000000000000000001"
let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let frozenAt = 10
let lastBlock = 60

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

let rpcHeight = ref(frozenAt + 2)

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port=rpcPort, ~getResult=(~method, ~params) =>
    ServedEvmChain.rpcResult(~logs, ~height=rpcHeight.contents, ~method, ~params)
  )
)

let hyperSync: ref<option<MockHyperSyncServer.t>> = ref(None)
Async.beforeAll(async () => {
  let server = MockHyperSyncServer.make(~height=frozenAt, ~port=hyperSyncPort)
  server->MockHyperSyncServer.serveChain(ServedEvmChain.hyperSyncChain(~logs, ~height=lastBlock))
  hyperSync := Some(server)
})
Async.afterAll(async () => hyperSync.contents->Option.forEach(MockHyperSyncServer.close))

let scenario = Scenario.make(
  ~configYaml=`
name: frozen-hypersync
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 1
    end_block: ${lastBlock->Int.toString}
    max_reorg_depth: 0
    hypersync_config:
      url: ${ServedEvmChain.url(hyperSyncPort)}
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: fallback
      polling_interval: 500
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

describe("A HyperSync instance that stopped following its chain", () => {
  Async.it(
    "Switches to the RPC fallback without querying HyperSync past its frozen height",
    async t => {
      let exited = ref(false)
      await scenario->Scenario.run(
        ~yamlSources=true,
        ~sourceTiming={
          newBlockStallTimeout: 1_000,
          newBlockStallTimeoutRealtime: 1_000,
          stalledPollingInterval: 500,
          reducedPollingInterval: 1_000,
          recoveryTimeout: 2_000.,
        },
        ~onExit=() => exited := true,
        async (~indexer, ~source as _) => {
          // Real time: HyperSync's first height and the backfill to it go over
          // real local I/O with no timer in between. Moving the clock before
          // they land could fire the first-height stall and recruit the RPC
          // before HyperSync has said where it is.
          let deadline = Date.now() +. 10_000.
          let backfilled = ref(false)
          while !backfilled.contents {
            let rows: array<seen> = await indexer.query("Seen")
            backfilled := rows->Array.length >= frozenAt
            if !backfilled.contents {
              if Date.now() > deadline {
                JsError.throwWithMessage("Timed out waiting for the backfill to the frozen height")
              }
              await Utils.delay(10)
            }
          }
          let steps = ref(0)
          while !exited.contents && steps.contents < 200 {
            // The chain moves on by a block a second.
            if mod(steps.contents, 2) === 0 && rpcHeight.contents < lastBlock {
              rpcHeight := rpcHeight.contents + 1
            }
            await indexer.advanceTime(500)
            // Real time: both sources' requests resolve on real local I/O.
            await Utils.delay(5)
            steps := steps.contents + 1
          }
          let rows: array<seen> = await indexer.query("Seen")
          let queriesPastFrozenHeight =
            hyperSync.contents
            ->Option.getOrThrow
            ->MockHyperSyncServer.takeQueries
            ->Array.filter(
              query =>
                query
                ->JSON.Decode.object
                ->Option.flatMap(query => query->Dict.get("from_block"))
                ->Option.flatMap(JSON.Decode.float)
                ->Option.getOr(0.) > frozenAt->Int.toFloat,
            )
          t.expect((
            exited.contents,
            rows->Array.length,
            queriesPastFrozenHeight->Array.length,
            indexer.infoAndAboveLogs()->Array.filterMap(
              ({msg, params}) =>
                msg->String.startsWith("HyperSync ") || msg == "Switching data-source"
                  ? Some((msg, params->Dict.get("source")))
                  : None,
            ),
          )).toEqual((
            true,
            lastBlock,
            // The stalled wait that recruits the fallback finds HyperSync blocks
            // behind it, so HyperSync is held before it is asked for anything.
            0,
            [
              (
                "Switching data-source",
                Some(JSON.String(`RPC (127.0.0.1:${rpcPort->Int.toString})`)),
              ),
            ],
          ))
        },
      )
    },
  )
})
