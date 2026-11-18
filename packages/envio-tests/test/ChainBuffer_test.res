open Vitest

// What the chain buffer keeps and what a batch builds from it, from a user's
// config.yaml and handlers to the rows the indexer writes, over a real HyperSync
// source. A fetched log is stored once, whatever number of handlers it reaches.

let token = "0x1111111111111111111111111111111111111111"
let factory = "0x2222222222222222222222222222222222222222"
let subFactory = "0x3333333333333333333333333333333333333333"
let grandchild = "0x4444444444444444444444444444444444444444"
let sender = "0x00000000000000000000000000000000000000aa"
let receiver = "0x00000000000000000000000000000000000000bb"

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let createdSighash = "0x1449abf21e49fd025f33495e77f7b1461caefdd3d4bb646424a3f445c4576a5b"

let transfer = (~blockNumber, ~address=token): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address,
  topics: [
    transferSighash,
    sender->ServedEvmChain.addressTopic,
    receiver->ServedEvmChain.addressTopic,
  ],
  data: 1n->ServedEvmChain.uintTopic,
}

let created = (~blockNumber, ~address, child): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address,
  topics: [createdSighash, child->ServedEvmChain.addressTopic],
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18701,
  ~rpcPort=18702,
  ~height=20,
  ~logs=[
    transfer(~blockNumber=3),
    transfer(~blockNumber=4),
    transfer(~blockNumber=5),
    transfer(~blockNumber=6),
    created(~blockNumber=9, ~address=factory, subFactory),
    created(~blockNumber=11, ~address=subFactory, grandchild),
    transfer(~blockNumber=13, ~address=grandchild),
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: chain-buffer
rollback_on_reorg: false
full_batch_size: 2
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: Factory
    events:
      - event: Created(address indexed child)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[],
      ~contracts=`
      - name: Token
        address: "${token}"
      - name: Factory
        address: "${factory}"`,
    )}
`,
  ~schema=ServedEvmChain.routedSchema,
  ~handlers=ServedEvmChain.routedHandlers ++
  `
// The factory at block 9 registers a factory, which registers a token at 11.
indexer.contractRegister({ contract: "Factory", event: "Created" }, async ({ event, context }) => {
  if (event.block.number === 9) context.chain.Factory.add(event.params.child);
  else context.chain.Token.add(event.params.child);
});

indexer.onEvent(
  { contract: "Token", event: "Transfer", where: { params: { from: "${sender}" } } },
  async ({ event, context }) => context.Routed.set(routed(event, "from")),
);
indexer.onEvent(
  { contract: "Token", event: "Transfer", where: { params: { to: "${receiver}" } } },
  async ({ event, context }) => context.Routed.set(routed(event, "to")),
);
`,
)

let sumOfValues = (metrics: array<IndexerRunner.metric>) =>
  metrics->Array.reduce(0., (sum, {value}) => sum +. value->Float.fromString->Option.getOr(0.))

let batchSizes = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filterMap(line =>
    switch (line->Dict.get("msg"), line->Dict.get("batchSize")) {
    // A batch that only moves progress carries no items.
    | (Some(JSON.String("Started processing")), Some(JSON.Number(size))) if size > 0. =>
      Some(size->Float.toInt)
    | _ => None
    }
  )

describe("Chain buffer", () => {
  Async.it(
    "stores a log once for two handlers, builds batches of about the item target, and follows a factory a factory registered",
    async t =>
      await served->ServedEvmChain.run(
        scenario,
        async indexer => {
          let fetchedRows =
            (await indexer.metric("envio_fetching_block_range_events_total"))->sumOfValues
          t.expect((
            await indexer->ServedEvmChain.readRouted,
            fetchedRows,
            indexer->batchSizes,
          )).toEqual((
            [3, 4, 5, 6, 13]
            ->Array.flatMap(
              blockNumber => [
                ServedEvmChain.routed(~chainId=1, ~blockNumber, "from"),
                ServedEvmChain.routed(~chainId=1, ~blockNumber, "to"),
              ],
            )
            ->ServedEvmChain.sorted,
            7.,
            // A batch ends at the first block boundary at or past its target.
            [2, 2, 2, 2, 1, 3],
          ))
        },
      ),
  )
})
