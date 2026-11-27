open Vitest

// The HyperSync client caches a query body on the server under a hash of
// everything but its block range, and uploads the body again on a miss. So a
// partition's consecutive queries must differ in their range alone, or every
// request pays a miss: a round trip and the whole address list uploaded again.

let token = "0x1000000000000000000000000000000000000001"
let pool = "0x2000000000000000000000000000000000000002"
let swapSighash = "0x3ebfdaaf4031bec9a2b7b0a1c594d2d03f3d0b8d68531c9164c2829bac00fefa"
// Past the last page the test pushes: a pushed page carries no logs, so a
// Swap it covers would never be served.
let swapBlocks = Array.fromInitializer(~length=7, i => 651 + 50 * i)

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18751,
  ~rpcPort=18752,
  ~height=1000,
  ~logs=swapBlocks->Array.map(blockNumber => {
    ServedEvmChain.blockNumber,
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

let selectsToken = (query: JSON.t) =>
  switch query {
  | Object(body) =>
    switch body->Dict.get("logs") {
    | Some(Array(selections)) =>
      selections->Array.some(selection =>
        switch selection {
        | Object(selection) =>
          switch selection->Dict.get("address") {
          | Some(Array(addresses)) => addresses->Array.includes(JSON.String(token))
          | _ => false
          }
        | _ => false
        }
      )
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
  // The client runs with its production settings: capnp, caching on.
  Async.it(
    "stays the same across a sparse partition's probes, so only the first uploads it",
    async t => {
      let {hyperSync} = served->ServedEvmChain.servers
      // The server stops short of the range each time, the way HyperSync does
      // at its time or size limit, so both partitions query again.
      [101, 201, 301, 401, 501, 601]->Array.forEach(
        nextBlock => hyperSync->MockHyperSyncServer.pushResponse({nextBlock: nextBlock}),
      )
      let routed = ref([])
      await served->ServedEvmChain.run(
        scenario,
        async indexer => {
          routed := (await indexer->ServedEvmChain.readRouted)
        },
      )

      let bodies =
        hyperSync
        ->MockHyperSyncServer.takeQueries
        ->Array.filter(selectsToken)
        ->Array.map(withoutRange)
      let uploads =
        hyperSync
        ->MockHyperSyncServer.takeUploads
        ->Array.filter(selectsToken)
        ->Array.map(withoutRange)
      t.expect((routed.contents, bodies->Array.length > 2, bodies, uploads)).toEqual((
        swapBlocks
        ->Array.map(blockNumber => ServedEvmChain.routed(~chainId=1, ~blockNumber, "Swap"))
        ->ServedEvmChain.sorted,
        true,
        Array.make(~length=bodies->Array.length, bodies->Array.getUnsafe(0)),
        [bodies->Array.getUnsafe(0)],
      ))
    },
  )
})
