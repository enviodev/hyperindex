open Vitest

// An RPC chain configured without a ws url has no height stream, so in
// realtime it has to poll its way to the next block.
let port = 18651

// The provider stays at the indexed head until it has been polled more than
// once in realtime, so the block can't come from the single poll that ends the
// backfill.
let height = ref(100)
let blockNumberCalls = ref(0)

let server = ref(None)
Async.beforeAll(async () => {
  server :=
    Some(
      await MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
        switch method {
        | "eth_blockNumber" =>
          blockNumberCalls := blockNumberCalls.contents + 1
          if blockNumberCalls.contents > 4 {
            height := 101
          }
          JSON.String(ServedEvmChain.hex(height.contents))
        | "eth_getLogs" => JSON.Array([])
        | "eth_getBlockByNumber" =>
          params
          ->JSON.Decode.array
          ->Option.getOrThrow
          ->Array.getUnsafe(0)
          ->ServedEvmChain.quantity
          ->ServedEvmChain.rpcBlock
        | "eth_chainId" => JSON.String(ServedEvmChain.hex(1337))
        | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
        }
      ),
    )
})
Async.afterAll(async () =>
  switch server.contents {
  | Some(server) => await server.closeAsync()
  | None => ()
  }
)

let scenario = Scenario.make(
  ~configYaml=`
name: rpc-realtime-polling
rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: http://127.0.0.1:${port->Int.toString}
      for: sync
      polling_interval: 10
    start_block: 100
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  ~handlers=`
import { indexer } from "envio";
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
`,
)

let metricValues = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.map(({value}) => value)

describe("RPC realtime without a ws url", () => {
  Async.it("advances by polling, with no height stream to report on", async t => {
    await scenario->Scenario.run(
      ~yamlSources=true,
      // A real RPC source against a local server: its polls resolve on real I/O.
      ~virtualTime=false,
      async (~indexer, ~source as _) => {
        let deadline = Date.now() +. 5_000.
        while (await indexer->metricValues("envio_progress_block")) != ["101"] {
          if Date.now() > deadline {
            JsError.throwWithMessage("Timed out waiting for block 101 to be indexed")
          }
          await Utils.delay(10)
        }
        t.expect((
          blockNumberCalls.contents > 4,
          await indexer->metricValues("envio_source_height_stream_connects_total"),
        )).toEqual((true, []))
      },
    )
  })
})
