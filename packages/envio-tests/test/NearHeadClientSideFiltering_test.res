open Vitest

// Once every partition of a chain is within 200 blocks of the head the chain
// can fetch, its dynamic contracts are fetched without their addresses: their
// partitions fold into the single address-free partition, so a new block costs
// one query instead of one per partition, and the query keeps the same shape
// while contracts keep being registered. Further back, queries keep sending
// addresses. The switch is per chain and sticky for the run.
let chainYaml = (~id, ~options="") =>
  `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0${options}
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"`

let scenarioOf = (~name, ~chains) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chains}
`,
    ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  )

let scenario = scenarioOf(~name="near-head-client-side-filtering", ~chains=chainYaml(~id=1337))

// Fetching stops 50 blocks short of the known head, so that is the head the
// 200 blocks are counted from.
let laggedScenario = scenarioOf(
  ~name="near-head-client-side-filtering-lag",
  ~chains=chainYaml(~id=1337, ~options="\n    block_lag: 50"),
)

let twoChainScenario = scenarioOf(
  ~name="near-head-client-side-filtering-two-chains",
  ~chains=chainYaml(~id=1337) ++ chainYaml(~id=100),
)

type gravatarOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": gravatarOps}}

let configAddress = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.unsafeFromString
let first = "0x1111111111111111111111111111111111111111"->Address.unsafeFromString
let second = "0x2222222222222222222222222222222222222222"->Address.unsafeFromString
let atHead = "0x3333333333333333333333333333333333333333"->Address.unsafeFromString

let register = (addresses): MockSource.mockSourceContractRegister =>
  async args => {
    let context = args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    addresses->Array.forEach(address => context.chain["Gravatar"].add(address))
  }

let lowercase = addresses =>
  addresses->Array.map(address => address->Address.toString->String.toLowerCase)

// A query's addresses come back lowercased, whatever the chain's address format.
let hasAddresses = addresses =>
  (query: MockSource.pendingItemsQuery) =>
    query->MockSource.addresses->Array.map(Address.toString) == addresses->lowercase

let isAddressBound = (query: MockSource.pendingItemsQuery) => query->MockSource.addresses != []

let upTo = (~knownHeight=?, block) => MockSource.Respond({
  items: [],
  latestFetchedBlockNumber: block,
  ?knownHeight,
})

describe("Near-head client-side filtering of dynamic contracts", () => {
  scenario->Scenario.it(
    "fetches every dynamic contract in one address-free query per new block",
    ~sources=[{chain: 1337}],
    // One address per partition, so the three Gravatar addresses take three
    // partitions and three queries per block until the switch folds them.
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let processed = []
      let record = (~blockNumber, ~logIndex): MockSource.mockSourceHandler =>
        async _ => processed->Array.push((blockNumber, logIndex))->ignore

      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(300)

      // Far from the head: the config address registers two dynamic
      // addresses, and each partition's query carries its own address.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          where: hasAddresses([configAddress]),
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first, second])}],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 10, where: hasAddresses([first]), reply: upTo(300)},
        {fromBlock: 10, where: hasAddresses([second]), reply: upTo(300)},
      ])

      // At the head: the next block is one query, carrying no addresses. A
      // contract registered by it gets a catch-up query from its registration
      // block, which delivers the event it emitted in that same block.
      sourceMock.resolveGetHeightOrThrow(301)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 301,
          where: hasAddresses([]),
          reply: Respond({
            items: [
              {
                blockNumber: 301,
                logIndex: 0,
                handler: record(~blockNumber=301, ~logIndex=0),
                contractRegister: register([atHead]),
              },
            ],
            latestFetchedBlockNumber: 301,
            knownHeight: 301,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 301,
          toBlock: Bounded(301),
          where: hasAddresses([atHead]),
          reply: Respond({
            items: [
              {blockNumber: 301, logIndex: 1, handler: record(~blockNumber=301, ~logIndex=1)},
            ],
            latestFetchedBlockNumber: 301,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      // The catch-up is gone and the head is back to one address-free query.
      sourceMock.resolveGetHeightOrThrow(302)
      await sourceMock.expectItemsQueries([
        {fromBlock: 302, where: hasAddresses([]), reply: upTo(302, ~knownHeight=302)},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (processed, sourceMock.pendingItemsQueries),
        ~message="both block-301 events are processed once, and no other query is in flight",
      ).toEqual(([(301, 0), (301, 1)], []))
    },
  )

  laggedScenario->Scenario.it(
    "counts the 200 blocks from the head the chain can fetch",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      // Known head 1000, fetchable head 950.
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first])}],
            latestFetchedBlockNumber: 950,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 10, where: hasAddresses([first]), reply: upTo(950)},
      ])

      // Fetchable head 1151, 201 blocks past the chain: still by address.
      sourceMock.resolveGetHeightOrThrow(1201)
      await sourceMock.expectItemsQueries([
        {fromBlock: 951, where: hasAddresses([configAddress]), reply: upTo(1151)},
        {fromBlock: 951, where: hasAddresses([first]), reply: upTo(1151)},
      ])

      // Fetchable head 1351, 200 blocks past the chain: one address-free query.
      // Measured from the known head, the chain would still be 250 blocks away.
      sourceMock.resolveGetHeightOrThrow(1401)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1152, where: hasAddresses([]), reply: upTo(1351)},
      ])

      t.expect(
        sourceMock.pendingItemsQueries,
        ~message="the address-free query fetched the rest of the range",
      ).toEqual([])
    },
  )

  scenario->Scenario.it(
    "names the partition holding a chain back from the switch",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      // The config partition reaches the head in one go, registering a
      // contract whose partition starts back at block 10.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first])}],
            latestFetchedBlockNumber: 1000,
          }),
        },
      ])
      // The response reports a newer head, as HyperSync's do, while the
      // partition is still 500 blocks behind it.
      let laggardPartitionId = ref("")
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 10,
          where: hasAddresses([first]),
          reply: RespondWith(
            query => {
              laggardPartitionId := query.partitionId
              {items: [], latestFetchedBlockNumber: 500, knownHeight: 1001}
            },
          ),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 501, where: hasAddresses([first]), reply: upTo(1001)},
        {fromBlock: 1001, where: hasAddresses([configAddress]), reply: upTo(1001)},
      ])

      sourceMock.resolveGetHeightOrThrow(1002)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1002, where: hasAddresses([]), reply: upTo(1002, ~knownHeight=1002)},
      ])

      t.expect(
        indexer.allLogsAsJson()->Array.filterMap(
          line =>
            switch line->Dict.get("msg") {
            | Some(String(msg)) if msg->String.includes("still catching up") =>
              Some((
                line->Dict.get("level"),
                line->Dict.get("partitionId"),
                line->Dict.get("latestFetchedBlock"),
                line->Dict.get("fetchTarget"),
              ))
            | _ => None
            },
        ),
        ~message="one trace line names the partition, while it is the one left behind",
      ).toEqual([
        (
          Some(JSON.String("trace")),
          Some(JSON.String(laggardPartitionId.contents)),
          Some(JSON.Number(500.)),
          Some(JSON.Number(1001.)),
        ),
      ])
    },
  )

  scenario->Scenario.it(
    "judges the distance against a head it just learned, not one a response repeats",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      // Like an RPC source, the responses below repeat the height their query
      // went out with, however long the backfill took.
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first])}],
            latestFetchedBlockNumber: 1000,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 10, where: hasAddresses([first]), reply: upTo(1000)},
      ])

      // Back at the head it knew, the chain learns the real one: 1000 blocks
      // went by meanwhile, and they are fetched by address.
      sourceMock.resolveGetHeightOrThrow(2000)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1001, where: hasAddresses([configAddress]), reply: upTo(2000)},
        {fromBlock: 1001, where: hasAddresses([first]), reply: upTo(2000)},
      ])

      sourceMock.resolveGetHeightOrThrow(2001)
      await sourceMock.expectItemsQueries([
        {fromBlock: 2001, where: hasAddresses([]), reply: upTo(2001, ~knownHeight=2001)},
      ])

      t.expect(
        sourceMock.pendingItemsQueries,
        ~message="the next head block is one address-free query",
      ).toEqual([])
    },
  )

  twoChainScenario->Scenario.it(
    "switches a chain at its head while another chain is still backfilling",
    ~sources=[{chain: 1337}, {chain: 100}],
    ~maxAddrInPartition=1,
    // Without realtime, a chain at its head polls for new blocks at the
    // reduced interval.
    ~sourceTiming={reducedPollingInterval: 1},
    async (~t, ~indexer, ~source) => {
      let atHeadChain = source(1337)
      let backfillingChain = source(100)
      atHeadChain.resolveGetHeightOrThrow(300)
      await atHeadChain.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first])}],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await atHeadChain.expectItemsQueries([
        {fromBlock: 10, where: hasAddresses([first]), reply: upTo(300)},
      ])

      // 1000 blocks short of its head, yet far enough along that cross-chain
      // alignment lets the other chain fetch its new blocks.
      backfillingChain.resolveGetHeightOrThrow(10_000)
      await backfillingChain.expectItemsQueries([{fromBlock: 1, reply: upTo(9_000)}])
      await backfillingChain.expectItemsQueries([{fromBlock: 9_001, reply: LeavePending}])

      atHeadChain.setAutoHeight(301)
      await indexer.advanceTime(1)
      await atHeadChain.expectItemsQueries([
        {fromBlock: 301, where: hasAddresses([]), reply: upTo(301, ~knownHeight=301)},
      ])

      t.expect(
        (
          atHeadChain.pendingItemsQueries,
          backfillingChain.pendingItemsQueries->Array.map(query => query->isAddressBound),
        ),
        ~message="the chain at its head is address-free while the other still backfills by address",
      ).toEqual(([], [true]))
    },
  )

  scenario->Scenario.it(
    "resumes a chain by address until it is back near the head",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(300)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 10, logIndex: 0, contractRegister: register([first, second])}],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 10, address: first->Address.toString, reply: upTo(300)},
        {fromBlock: 10, address: second->Address.toString, reply: upTo(300)},
      ])
      await indexer.getBatchWritePromise()

      // Down while the head moved 300 blocks on.
      let _ = await indexer.restart()
      sourceMock.resolveGetHeightOrThrow(600)
      let gapAddresses = []
      let respondUpTo600 = MockSource.RespondWith(
        query => {
          gapAddresses->Array.push(query->MockSource.addresses)->ignore
          {items: [], latestFetchedBlockNumber: 600, knownHeight: 600}
        },
      )
      // The query budget lets two partitions out at first, the third once one
      // of them is answered.
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 301, where: isAddressBound, reply: respondUpTo600},
        {partitionId: "1", fromBlock: 301, where: isAddressBound, reply: respondUpTo600},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 301, where: isAddressBound, reply: respondUpTo600},
      ])

      sourceMock.resolveGetHeightOrThrow(601)
      await sourceMock.expectItemsQueries([
        {fromBlock: 601, where: hasAddresses([]), reply: upTo(601, ~knownHeight=601)},
      ])

      t.expect(
        (
          gapAddresses
          ->Array.map(lowercase)
          ->Array.toSorted((a, b) => Array.compare(a, b, String.compare)),
          sourceMock.pendingItemsQueries,
        ),
        ~message="the 300-block gap is fetched one address per query, and the head block is one address-free query",
      ).toEqual(([[first], [second], [configAddress]]->Array.map(lowercase), []))
    },
  )
})
