open Vitest

// https://github.com/enviodev/hyperindex/issues/1782
// A chain that rolls back reads every block reorg detection compares fresh,
// however far below the 200 blocks a lagging node could leave out they reach.
let port = 18552
let head = 600
let maxReorgDepth = 300

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 105, value: 3, logIndex: 0}]

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    switch method {
    | "eth_chainId" => JSON.String(RpcE2eChain.hex(1337))
    | _ => RpcE2eChain.resultFor(~transfers, ~height=head, ~method, ~params)
    }
  )
)

let scenario = Scenario.make(
  ~configYaml=`
name: rpc-rollback-reorg-window
chains:
  - id: 1337
    start_block: 100
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    block_lag: 0
    rpc:
      url: http://127.0.0.1:${port->Int.toString}
      for: sync
      initial_block_interval: 100
      interval_ceiling: 100
    contracts:
      - name: Token
        address: "${RpcE2eChain.contractAddress}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
)

describe("Backfilling a chain that rolls back over RPC", () => {
  Async.it("reads every block reorg detection compares", async t => {
    await scenario->Scenario.run(
      ~yamlSources=true,
      // A real RPC source against a local server: its reads resolve on real I/O.
      ~virtualTime=false,
      async (~indexer, ~source as _) => {
        // Real time: the pages are read over HTTP from the local server.
        let deadline = Date.now() +. 10_000.
        while (
          (await indexer.metric("envio_progress_block"))->Array.map(({value}) => value) != [
              head->Int.toString,
            ]
        ) {
          if Date.now() > deadline {
            JsError.throwWithMessage(`Timed out waiting for block ${head->Int.toString}`)
          }
          await Utils.delay(10)
        }
      },
    )

    // Reorg detection compares from 600 - 300. Catch-up stops one block below
    // that, so block 300 is read by a page that already knows it is reorgable.
    t.expect(mock()->RpcE2eChain.distinctBlocksRead).toEqual(
      [105]->Array.concat(
        Array.fromInitializer(~length=maxReorgDepth + 1, i => head - maxReorgDepth + i),
      ),
    )
  })
})
