open Vitest

// Once the indexer is realtime, dynamic contracts are fetched without their
// addresses: every partition holding them folds into the single address-free
// partition, so a new block costs one query instead of one per partition, and
// the query keeps the same shape while contracts keep being registered. Backfill
// keeps sending addresses.
let scenario = Scenario.make(
  ~configYaml=`
name: realtime-client-side-filtering
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
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

// A query's addresses come back lowercased, whatever the chain's address format.
let hasAddresses = addresses =>
  (query: MockSource.pendingItemsQuery) =>
    query->MockSource.addresses->Array.map(Address.toString) ==
      addresses->Array.map(address => address->Address.toString->String.toLowerCase)

describe("Realtime client-side filtering of dynamic contracts", () => {
  scenario->Scenario.it(
    "fetches every dynamic contract in one address-free query per new block",
    ~sources=[{chain: 1337}],
    // One address per partition, so the three Gravatar addresses take three
    // partitions and three queries per block until realtime folds them.
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let processed = []
      let record = (~blockNumber, ~logIndex): MockSource.mockSourceHandler =>
        async _ => processed->Array.push((blockNumber, logIndex))->ignore

      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(300)

      // Backfill: the config address registers two dynamic addresses, and each
      // partition's query carries its own address.
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
        {
          fromBlock: 10,
          where: hasAddresses([first]),
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
        {
          fromBlock: 10,
          where: hasAddresses([second]),
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.waitUntilReady()

      // Realtime: the next block is one query, carrying no addresses. A
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
        {
          fromBlock: 302,
          where: hasAddresses([]),
          reply: Respond({items: [], latestFetchedBlockNumber: 302, knownHeight: 302}),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (processed, sourceMock.pendingItemsQueries),
        ~message="both block-301 events are processed once, and no other query is in flight",
      ).toEqual(([(301, 0), (301, 1)], []))
    },
  )

  scenario->Scenario.it(
    "resumes a realtime chain by address until it is back at the head",
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
        {
          fromBlock: 10,
          address: first->Address.toString,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
        {
          fromBlock: 10,
          address: second->Address.toString,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.waitUntilReady()

      // Down for 20 blocks: the gap is backfill, so it keeps the addresses.
      let _ = await indexer.restart()
      sourceMock.resolveGetHeightOrThrow(320)
      // The partitions may go out one after another, so each is answered as it comes.
      let gapAddresses = []
      for _ in 1 to 3 {
        await sourceMock.expectItemsQueries([
          {
            fromBlock: 301,
            where: query => query->MockSource.addresses != [],
            reply: RespondWith(
              query => {
                gapAddresses->Array.push(query->MockSource.addresses)->ignore
                {items: [], latestFetchedBlockNumber: 320, knownHeight: 320}
              },
            ),
          },
        ])
      }

      // Back at the head, the chain goes address-free.
      sourceMock.resolveGetHeightOrThrow(321)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 321,
          where: hasAddresses([]),
          reply: Respond({items: [], latestFetchedBlockNumber: 321, knownHeight: 321}),
        },
      ])

      let lowercase = addresses =>
        addresses->Array.map(address => address->Address.toString->String.toLowerCase)
      t.expect(
        (
          gapAddresses
          ->Array.map(lowercase)
          ->Array.toSorted((a, b) => Array.compare(a, b, String.compare)),
          sourceMock.pendingItemsQueries,
        ),
        ~message="the gap is fetched one address per query, and the head block is the chain's one address-free query",
      ).toEqual(([[first], [second], [configAddress]]->Array.map(lowercase), []))
    },
  )
})
