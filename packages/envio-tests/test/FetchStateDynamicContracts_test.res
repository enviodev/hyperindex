open Vitest
open ItemsQueryView.Summary

let gravatar = "0x1111111111111111111111111111111111111111"
let nftFactory = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let address1 = "0x0000000000000000000000000000000000000001"
let address2 = "0x0000000000000000000000000000000000000002"
let address3 = "0x0000000000000000000000000000000000000003"
let address4 = "0x0000000000000000000000000000000000000004"

// Gravatar and NftFactory have handlers; UnknownContract and UntrackedContract
// are in the config without a single one. Each `Register` event registers its
// `contractAddress` for the contract it names.
//
// The mock source hangs its own registration on the chain's first contract, so
// that one has to be a contract with handlers anyway.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-dynamic-contracts
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Gravatar
        address: "${gravatar}"
        events:
          - event: "Register(string contractName, address contractAddress)"
      - name: NftFactory
        events:
          - event: "Register(string contractName, address contractAddress)"
      - name: UnknownContract
        events:
          - event: "Ping()"
      - name: UntrackedContract
        events:
          - event: "Ping()"
`,
  ~handlers=`
import { indexer } from "envio";

type Address = \`0x\${string}\`;
type RegisterArgs = {
  event: { params: { contractName: string; contractAddress: Address } };
  context: {
    chain: {
      Gravatar: { add: (address: Address) => void };
      NftFactory: { add: (address: Address) => void };
      UnknownContract: { add: (address: Address) => void };
      UntrackedContract: { add: (address: Address) => void };
    };
  };
};

const register = async ({ event, context }: RegisterArgs) => {
  const { contractName, contractAddress } = event.params;
  if (contractName === "Gravatar") context.chain.Gravatar.add(contractAddress);
  if (contractName === "NftFactory") context.chain.NftFactory.add(contractAddress);
  if (contractName === "UnknownContract") context.chain.UnknownContract.add(contractAddress);
  if (contractName === "UntrackedContract") context.chain.UntrackedContract.add(contractAddress);
};

indexer.contractRegister({ contract: "Gravatar", event: "Register" }, register);
indexer.contractRegister({ contract: "NftFactory", event: "Register" }, register);

indexer.onEvent({ contract: "Gravatar", event: "Register" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "Register" }, async () => {});
`,
)

let register = (
  ~blockNumber,
  ~logIndex=0,
  ~emitter="Gravatar",
  ~srcAddress=gravatar,
  contractName,
  contractAddress,
): MockSource.itemMock => {
  event: `${emitter}.Register`,
  blockNumber,
  logIndex,
  srcAddress,
  params: dict{
    "contractName": contractName->(Utils.magic: string => unknown),
    "contractAddress": contractAddress->(Utils.magic: string => unknown),
  },
}

let dynamicAddressRows = async (indexer: IndexerRunner.t) =>
  (await indexer.queryAddresses())
  ->Array.filter(row => row.registrationBlock !== -1)
  ->Array.map(row => (row.address->Address.toString, row.contractName, row.registrationBlock))

let sources: array<Scenario.sourceMock> = [{chain: 1337, autoHeight: 1000}]

// Answers partition "0"'s first query up to `latestFetchedBlockNumber` with
// `items`, then reads the queries the registrations leave the chain issuing.
let registerInFirstResponse = async (
  sourceMock: MockSource.t,
  ~indexer: IndexerRunner.t,
  ~latestFetchedBlockNumber=100,
  items,
) => {
  await sourceMock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 0,
      reply: Respond({items, latestFetchedBlockNumber}),
    },
  ])
  // The partition's next query goes out with the response; the registrations
  // land once the contractRegister run over the response's blocks ends.
  await indexer.waitUntilIdle()
  await sourceMock.expectItemsQueries([
    {partitionId: "0", fromBlock: latestFetchedBlockNumber + 1, reply: LeavePending},
    {reply: LeavePending},
  ])
  sourceMock.pendingItemsQueries->summarize
}

// Answers every pending query to its end, which carries the chain's progress
// past every registration so far, so they are all persisted.
let fetchPendingAndReadRows = async (sourceMock: MockSource.t, indexer: IndexerRunner.t) => {
  sourceMock.drainPendingItemsQueries()
  await indexer.waitUntilIdle()
  await dynamicAddressRows(indexer)
}

let staticPartitionQuery = (~fromBlock=101, ~toBlock=MockSource.Bounded(800), addresses) => {
  partitionId: "0",
  fromBlock,
  toBlock,
  addresses: addresses->Array.concat([gravatar])->Array.toSorted(String.compare),
}

describe("Dynamic contract registration", () => {
  scenario->Scenario.it(
    "leaves the partitions as they were when a contractRegister registers nothing",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [register(~blockNumber=10, "NoSuchContract", address1)],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [staticPartitionQuery([])],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "skips registering an address the config already holds for the contract",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [register(~blockNumber=10, "Gravatar", gravatar)],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [staticPartitionQuery([])],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "stores an address once for each contract without handlers that claims it, and never fetches it",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let respond = (
        ~fromBlock,
        ~latestFetchedBlockNumber,
        item,
      ): MockSource.expectedItemsQuery => {
        partitionId: "0",
        fromBlock,
        reply: Respond({items: [item], latestFetchedBlockNumber}),
      }
      await sourceMock.expectItemsQueries([
        respond(
          ~fromBlock=0,
          ~latestFetchedBlockNumber=100,
          register(~blockNumber=10, "UnknownContract", address1),
        ),
      ])
      await sourceMock.expectItemsQueries([
        respond(
          ~fromBlock=101,
          ~latestFetchedBlockNumber=800,
          register(~blockNumber=200, "UntrackedContract", address1),
        ),
      ])
      await sourceMock.expectItemsQueries([
        respond(
          ~fromBlock=801,
          ~latestFetchedBlockNumber=900,
          register(~blockNumber=850, "UnknownContract", address1),
        ),
      ])
      await sourceMock.expectItemsQueries([{partitionId: "0", fromBlock: 901, reply: LeavePending}])
      await indexer.waitUntilIdle()
      t.expect((
        sourceMock.pendingItemsQueries->summarize,
        await dynamicAddressRows(indexer),
      )).toEqual((
        [staticPartitionQuery(~fromBlock=901, ~toBlock=Bounded(1000), [])],
        [(address1, "UnknownContract", 10), (address1, "UntrackedContract", 200)],
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1187
  scenario->Scenario.it(
    "stores an address the config holds for another contract, for a contract without handlers",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [register(~blockNumber=10, "UnknownContract", gravatar)],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [staticPartitionQuery([])],
        [(gravatar, "UnknownContract", 10)],
      ))
    },
  )

  scenario->Scenario.it(
    "fetches only the registration of a contract with handlers from a mixed batch",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=5, "UnknownContract", address2),
          register(~blockNumber=5, ~logIndex=1, "Gravatar", address1),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery([]),
          {partitionId: "1", fromBlock: 5, toBlock: Bounded(800), addresses: [address1]},
        ],
        [(address2, "UnknownContract", 5), (address1, "Gravatar", 5)],
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1187
  scenario->Scenario.it(
    "fetches one address under each of two contracts registering it in one batch",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=10, "Gravatar", address1),
          register(~blockNumber=10, ~logIndex=1, "NftFactory", address1),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery([]),
          {partitionId: "1", fromBlock: 10, toBlock: Bounded(800), addresses: [address1]},
          {partitionId: "2", fromBlock: 10, toBlock: Bounded(800), addresses: [address1]},
        ],
        [(address1, "Gravatar", 10), (address1, "NftFactory", 10)],
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1187
  scenario->Scenario.it(
    "fetches an address for a contract with handlers after a contract without them claimed it",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=10, "UnknownContract", address1),
          register(~blockNumber=10, ~logIndex=1, "Gravatar", address1),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery([]),
          {partitionId: "1", fromBlock: 10, toBlock: Bounded(800), addresses: [address1]},
        ],
        [(address1, "UnknownContract", 10), (address1, "Gravatar", 10)],
      ))
    },
  )

  scenario->Scenario.it(
    "registers every address after a skipped one in the same batch",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=10, "Gravatar", gravatar),
          register(~blockNumber=10, ~logIndex=1, "Gravatar", address1),
          register(~blockNumber=10, ~logIndex=2, "Gravatar", address2),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery([]),
          {
            partitionId: "1",
            fromBlock: 10,
            toBlock: Bounded(800),
            addresses: [address1, address2],
          },
        ],
        [(address1, "Gravatar", 10), (address2, "Gravatar", 10)],
      ))
    },
  )

  scenario->Scenario.it(
    "registers the earliest of two registrations of one address in a batch",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=10, "Gravatar", address1),
          register(~blockNumber=20, "Gravatar", address1),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery([]),
          {partitionId: "1", fromBlock: 10, toBlock: Bounded(800), addresses: [address1]},
        ],
        [(address1, "Gravatar", 10)],
      ))
    },
  )

  scenario->Scenario.it(
    "splits a batch of registrations over maxAddrInPartition into several partitions",
    ~sources,
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=2, "Gravatar", address1),
          register(~blockNumber=2, ~logIndex=1, "Gravatar", address2),
          register(~blockNumber=2, ~logIndex=2, "Gravatar", address3),
          register(~blockNumber=2, ~logIndex=3, "Gravatar", address4),
        ],
      )
      t.expect(queries).toEqual([
        staticPartitionQuery([]),
        {
          partitionId: "1",
          fromBlock: 2,
          toBlock: Bounded(800),
          addresses: [address1, address2, address3],
        },
        {partitionId: "2", fromBlock: 2, toBlock: Bounded(800), addresses: [address4]},
      ])
    },
  )

  scenario->Scenario.it(
    "keeps each contract's registrations in partitions of their own",
    ~sources,
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=2, "NftFactory", address1),
          register(~blockNumber=2, ~logIndex=1, "Gravatar", address2),
          register(~blockNumber=2, ~logIndex=2, "Gravatar", address3),
          register(~blockNumber=2, ~logIndex=3, "NftFactory", address4),
        ],
      )
      t.expect(queries).toEqual([
        staticPartitionQuery([]),
        {partitionId: "1", fromBlock: 2, toBlock: Bounded(800), addresses: [address1, address4]},
        {partitionId: "2", fromBlock: 2, toBlock: Bounded(800), addresses: [address2, address3]},
      ])
    },
  )

  scenario->Scenario.it(
    "groups a batch's registrations into one partition unless they are too far apart",
    ~sources=[{chain: 1337, autoHeight: 1_000_000}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 0,
          reply: Respond({
            items: [
              register(~blockNumber=2, "Gravatar", address1),
              register(~blockNumber=10_000, "Gravatar", address2),
              register(~blockNumber=300_000, "Gravatar", address3),
            ],
            latestFetchedBlockNumber: 400_000,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([{reply: LeavePending}])
      let first = sourceMock.pendingItemsQueries->summarize
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          reply: Respond({items: [], latestFetchedBlockNumber: 100_000}),
        },
      ])
      await sourceMock.expectItemsQueries([{reply: LeavePending}])
      let earlyAddresses = [address1, address2]
      t.expect(
        (first, sourceMock.pendingItemsQueries->summarize),
        ~message="the far registration waits in a partition of its own until the earlier ones catch up",
      ).toEqual((
        [{partitionId: "1", fromBlock: 2, toBlock: Bounded(999_800), addresses: earlyAddresses}],
        [
          staticPartitionQuery(~fromBlock=400_001, ~toBlock=Bounded(999_800), []),
          {
            partitionId: "1",
            fromBlock: 100_001,
            toBlock: Bounded(999_800),
            addresses: earlyAddresses,
          },
          {partitionId: "2", fromBlock: 300_000, toBlock: Bounded(999_800), addresses: [address3]},
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "reports a re-registration from an earlier block and doesn't fetch it from there",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let _ = await sourceMock->registerInFirstResponse(
        ~indexer,
        [
          register(~blockNumber=3, "NftFactory", nftFactory),
          register(~blockNumber=10, "Gravatar", address1),
        ],
      )
      let registerFromNftFactory = (~blockNumber, ~logIndex=0) =>
        register(
          ~blockNumber,
          ~logIndex,
          ~emitter="NftFactory",
          ~srcAddress=nftFactory,
          "Gravatar",
          address1,
        )
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 3,
          reply: Respond({
            items: [
              registerFromNftFactory(~blockNumber=5),
              registerFromNftFactory(~blockNumber=10, ~logIndex=1),
              registerFromNftFactory(~blockNumber=50),
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
        {partitionId: "0", reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
      ])
      // The re-registrations are made by the contractRegister run that follows
      // the response.
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {partitionId: "1", fromBlock: 101, reply: LeavePending},
        {reply: LeavePending},
      ])
      t.expect((
        sourceMock.pendingItemsQueries->summarize,
        indexer.infoAndAboveLogs()->Array.filter(({msg}) => msg->String.startsWith("Skipping")),
      )).toEqual((
        [
          staticPartitionQuery([]),
          {partitionId: "1", fromBlock: 101, toBlock: Bounded(800), addresses: [nftFactory]},
          {partitionId: "2", fromBlock: 10, toBlock: Bounded(800), addresses: [address1]},
        ],
        [
          {
            IndexerRunner.msg: "Skipping same-contract re-registration: the address is already registered for this contract. The start block does not move earlier.",
            params: dict{
              "chainId": JSON.Number(1337.),
              "contractName": JSON.String("Gravatar"),
              "contractAddress": JSON.String(address1),
              "registeredFromBlock": JSON.Number(10.),
              "requestedFromBlock": JSON.Number(5.),
            },
          },
        ],
      ))
    },
  )
})

describe("Dynamic contract start blocks", () => {
  scenario->Scenario.it(
    "fetches each registered address from the block that registered it",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let queries = await sourceMock->registerInFirstResponse(
        ~indexer,
        ~latestFetchedBlockNumber=400,
        [
          register(~blockNumber=150, "Gravatar", address1),
          register(~blockNumber=300, "Gravatar", address2),
        ],
      )
      t.expect((queries, await fetchPendingAndReadRows(sourceMock, indexer))).toEqual((
        [
          staticPartitionQuery(~fromBlock=401, []),
          {
            partitionId: "1",
            fromBlock: 150,
            toBlock: Bounded(800),
            addresses: [address1, address2],
          },
        ],
        [(address1, "Gravatar", 150), (address2, "Gravatar", 300)],
      ))
    },
  )
})
