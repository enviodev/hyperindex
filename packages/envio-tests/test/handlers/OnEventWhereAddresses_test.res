open Vitest

// A `where` that filters an event's params by `chain.<Contract>.addresses`,
// from a user's config.yaml and handler source to the rows the indexer writes.
// The filter follows the contract's addresses as they change: one comes from
// config.yaml, another from a contractRegister mid-run. Chain 1 fetches over
// HyperSync and chain 2 over RPC, both from the same served logs.

let factory = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
let emitter = "0x4444444444444444444444444444444444444444"
let configured = "0x1111111111111111111111111111111111111111"
let registered = "0x2222222222222222222222222222222222222222"
// Created like `registered`, but the contractRegister's own `where` skips it.
let skipped = "0x3333333333333333333333333333333333333333"
let outsider = "0x000000000000000000000000000000000000dEaD"
let zero = "0x0000000000000000000000000000000000000000"

let createdSighash = "0x1449abf21e49fd025f33495e77f7b1461caefdd3d4bb646424a3f445c4576a5b"
let movedSighash = "0x000e6e1d52477156459d942cdb0bc0970a404c1ea857ab5b75b5ad32f334dfc1"

let created = (~blockNumber, registry): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address: factory,
  topics: [createdSighash, registry->ServedEvmChain.addressTopic],
}

let moved = (~blockNumber, ~logIndex=0, ~from, ~to): ServedEvmChain.log => {
  blockNumber,
  logIndex,
  address: emitter,
  topics: [movedSighash, from->ServedEvmChain.addressTopic, to->ServedEvmChain.addressTopic],
  data: 1n->ServedEvmChain.uintTopic,
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18613,
  ~rpcPort=18614,
  ~height=12,
  ~logs=[
    moved(~blockNumber=3, ~from=zero, ~to=configured),
    moved(~blockNumber=3, ~logIndex=1, ~from=zero, ~to=outsider),
    // Before the contractRegister adds `registered`, so not yet its address.
    moved(~blockNumber=4, ~from=registered, ~to=zero),
    created(~blockNumber=5, registered),
    created(~blockNumber=6, skipped),
    moved(~blockNumber=8, ~from=registered, ~to=zero),
    moved(~blockNumber=8, ~logIndex=1, ~from=zero, ~to=skipped),
    moved(~blockNumber=9, ~from=configured, ~to=registered),
  ],
)

let registerHandler = `
indexer.contractRegister(
  { contract: "Factory", event: "Created", where: { params: { registry: "${registered}" } } },
  async ({ event, context }) => {
    context.chain.Registry.add(event.params.registry);
  },
);
`

let scenario = (~registries, ~handlers) =>
  Scenario.make(
    ~configYaml=`
name: on-event-where-addresses
rollback_on_reorg: false
contracts:
  - name: Factory
    events:
      - event: Created(address indexed registry)
  - name: Registry
    events:
      - event: Moved(address indexed from, address indexed to, uint256 amount)
chains:${served->ServedEvmChain.chainsYaml(
        ~hyperSync=[1],
        ~rpc=[2],
        ~contracts=`
      - name: Factory
        address: "${factory}"
      - name: Registry
        address: [${registries->Array.map(address => `"${address}"`)->Array.join(", ")}]`,
      )}
`,
    ~schema=ServedEvmChain.routedSchema,
    ~handlers=ServedEvmChain.routedHandlers ++ registerHandler ++ handlers,
  )

let toOrFromZero = scenario(
  ~registries=[configured],
  ~handlers=`
// A different \`where\` than the contractRegister's above, so the two act
// independently: every Created gets a row, only that one registers an address.
indexer.onEvent({ contract: "Factory", event: "Created" }, async ({ event, context }) =>
  context.Routed.set(routed(event, "Created")),
);

const ZERO = "0x0000000000000000000000000000000000000000" as const;
indexer.onEvent(
  {
    contract: "Registry",
    event: "Moved",
    wildcard: true,
    where: ({ chain }) => {
      const registries = chain.Registry.addresses;
      return {
        params: [
          { from: ZERO, to: registries },
          { from: registries, to: ZERO },
        ],
      };
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "Moved")),
);
`,
)

// Both params at once: a move between two of the contract's addresses.
let between = (~registries) =>
  scenario(
    ~registries,
    ~handlers=`
indexer.onEvent(
  {
    contract: "Registry",
    event: "Moved",
    wildcard: true,
    where: ({ chain }) => ({
      params: { from: chain.Registry.addresses, to: chain.Registry.addresses },
    }),
  },
  async ({ event, context }) => context.Routed.set(routed(event, "Moved")),
);
`,
  )

let expectedRows =
  [1, 2]
  ->Array.flatMap(chainId => [
    ServedEvmChain.routed(~chainId, ~blockNumber=3, "Moved"),
    ServedEvmChain.routed(~chainId, ~blockNumber=5, "Created"),
    ServedEvmChain.routed(~chainId, ~blockNumber=6, "Created"),
    ServedEvmChain.routed(~chainId, ~blockNumber=8, "Moved"),
  ])
  ->ServedEvmChain.sorted

let expectedBetweenRows =
  [1, 2]->Array.map(chainId => ServedEvmChain.routed(~chainId, ~blockNumber=9, "Moved"))

let zeroTopic = zero->ServedEvmChain.addressTopic

// The registry addresses each source asked for in Moved's from/to positions,
// and whether any Moved filter left one of them open — which is how a filter
// whose addresses are matched client-side goes out.
let movedAddressTopics = (queries: array<ServedEvmChain.query>) => {
  let filters =
    queries
    ->Array.flatMap(query => query.filters)
    ->Array.filter(filter => filter.topics->Array.get(0) == Some([movedSighash]))
  let addresses =
    filters
    ->Array.flatMap(filter => filter.topics->Array.slice(~start=1, ~end=3)->Array.flat)
    ->Array.filter(topic => topic !== zeroTopic)
  (
    addresses->Set.fromArray->Set.values->Array.fromIterator->ServedEvmChain.sorted,
    filters->Array.some(filter =>
      [1, 2]->Array.some(position =>
        filter.topics->Array.get(position)->Option.mapOr(true, Array.isEmpty)
      )
    ),
  )
}

let readRoutedAndQueries = async indexer => (
  await indexer->ServedEvmChain.readRouted,
  served->ServedEvmChain.takeHyperSyncQueries->movedAddressTopics,
  served->ServedEvmChain.takeRpcQueries->movedAddressTopics,
)

describe("onEvent where chain.<Contract>.addresses", () => {
  Async.it(
    "asks each source for the contract's addresses, including one registered mid-run",
    async t =>
      await served->ServedEvmChain.run(
        toOrFromZero,
        async indexer => {
          let expectedAddressTopics = (
            [configured, registered]->Array.map(ServedEvmChain.addressTopic)->ServedEvmChain.sorted,
            false,
          )
          t.expect(await readRoutedAndQueries(indexer)).toEqual((
            expectedRows,
            expectedAddressTopics,
            expectedAddressTopics,
          ))
        },
      ),
  )

  // Past the threshold a contract's addresses stop going out with the query
  // and are matched as the logs come back instead. The rows must not change.
  Async.it("indexes the same logs once the addresses are filtered client-side", async t =>
    await served->ServedEvmChain.run(
      toOrFromZero,
      ~clientFilterAddressThreshold=1,
      async indexer =>
        t.expect(await readRoutedAndQueries(indexer)).toEqual((
          expectedRows,
          // Only the configured address ever went out, before the registered
          // one took the contract past the threshold.
          ([configured->ServedEvmChain.addressTopic], true),
          ([configured->ServedEvmChain.addressTopic], true),
        )),
    )
  )

  Async.it("matches a log whose params are both the contract's addresses", async t =>
    await served->ServedEvmChain.run(
      between(~registries=[configured, registered]),
      async indexer =>
        t.expect(await indexer->ServedEvmChain.readRouted).toEqual(expectedBetweenRows),
    )
  )

  Async.it("matches it client-side when one of the addresses was registered mid-run", async t =>
    await served->ServedEvmChain.run(
      between(~registries=[configured]),
      ~clientFilterAddressThreshold=1,
      async indexer =>
        t.expect(await indexer->ServedEvmChain.readRouted).toEqual(expectedBetweenRows),
    )
  )

  // Fails today: each address set is queried with only its own addresses in
  // both positions, and `configured` and `registered` sit in different ones
  // since they start at different blocks, so a move between them is asked of
  // neither query.
  Async.it_fails(
    "matches it server-side when one of the addresses was registered mid-run",
    async t =>
      await served->ServedEvmChain.run(
        between(~registries=[configured]),
        async indexer =>
          t.expect(await indexer->ServedEvmChain.readRouted).toEqual(expectedBetweenRows),
      ),
  )
})
