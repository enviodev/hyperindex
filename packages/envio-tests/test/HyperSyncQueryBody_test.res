open Vitest

// The HyperSync client caches a query body on the server under a hash of
// everything but its block range, and uploads the body again on a miss. So a
// partition's consecutive queries must differ in their range alone, or every
// request pays a miss: a round trip and the whole address list uploaded again.

let token = "0x1000000000000000000000000000000000000001"
let pool = "0x2000000000000000000000000000000000000002"
let swapSighash = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18751,
  ~rpcPort=18752,
  ~height=1000,
  ~logs=Array.fromInitializer(~length=20, i => {
    ServedEvmChain.blockNumber: 50 * i + 1,
    logIndex: 0,
    address: pool,
    topics: [swapSighash],
  }),
)

// Token's partition never sees an event, so it probes on every request. The
// wildcard Swap sits in a partition of its own, at a cursor of its own.
let scenario = Scenario.make(
  ~configYaml=`
name: hypersync-query-body
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: Pool
    events:
      - event: Swap()
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[],
      ~contracts=`
      - name: Token
        address: "${token}"`,
    )}
`,
  ~schema=ServedEvmChain.routedSchema,
  ~handlers=ServedEvmChain.routedHandlers ++ `
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) =>
  context.Routed.set(routed(event, "Transfer")),
);
indexer.onEvent({ contract: "Pool", event: "Swap", wildcard: true }, async ({ event, context }) =>
  context.Routed.set(routed(event, "Swap")),
);
`,
)

let selectsAnAddress = (query: JSON.t) =>
  switch query {
  | Object(body) =>
    switch body->Dict.get("logs") {
    | Some(Array([Object(selection)])) => selection->Dict.get("address")->Option.isSome
    | _ => false
    }
  | _ => false
  }

let withoutRange = (query: JSON.t) => {
  let body = query->JSON.Decode.object->Option.getOrThrow->Dict.copy
  body->Dict.delete("from_block")
  body->Dict.delete("to_block")
  JSON.Object(body)
}

describe("HyperSync query body", () => {
  Async.it("stays the same across a sparse partition's probes", async t => {
    let {hyperSync} = served->ServedEvmChain.servers
    // The server stops short of the range each time, the way HyperSync does at
    // its time or size limit, so both partitions query again.
    [101, 201, 301, 401, 501, 601]->Array.forEach(
      nextBlock => hyperSync->MockHyperSyncServer.pushResponse({nextBlock: nextBlock}),
    )
    await served->ServedEvmChain.run(scenario, async _ => ())

    let bodies =
      hyperSync
      ->MockHyperSyncServer.takeQueries
      ->Array.filter(selectsAnAddress)
      ->Array.map(withoutRange)
    t.expect((bodies->Array.length > 2, bodies)).toEqual((
      true,
      Array.make(~length=bodies->Array.length, bodies->Array.getUnsafe(0)),
    ))
  })
})
