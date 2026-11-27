open Vitest
open ItemsQueryView.Summary

let factory0 = "0xf000000000000000000000000000000000000000"
let factory1 = "0xf000000000000000000000000000000000000001"
let gravatar2 = "0x1000000000000000000000000000000000000002"
let gravatar3 = "0x1000000000000000000000000000000000000003"
let simpleNft1 = "0x5000000000000000000000000000000000000001"
let simpleNft2 = "0x5000000000000000000000000000000000000002"
let simpleNft3 = "0x5000000000000000000000000000000000000003"
let gravatar4 = "0x1000000000000000000000000000000000000004"
let factory5 = "0xf000000000000000000000000000000000000005"
let contractA = "0xa000000000000000000000000000000000000001"
let contractB = "0xb000000000000000000000000000000000000001"

type selectionSummary = {
  partitionId: string,
  dependsOnAddresses: bool,
  events: array<string>,
}

let summarizeSelections = (queries: array<MockSource.pendingItemsQuery>) =>
  queries
  ->Array.map(query => {
    let selection = query->MockSource.selection
    {
      partitionId: query.partitionId,
      dependsOnAddresses: selection.dependsOnAddresses,
      events: selection.onEventRegistrations->Array.map(registration =>
        `${registration.eventConfig.contractName}.${registration.eventConfig.name}`
      ),
    }
  })
  ->Array.toSorted((a, b) => String.compare(a.partitionId, b.partitionId))

let chainYaml = (~name, ~contracts) =>
  `
name: ${name}
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:${contracts}
`

// Gravatar has only wildcard handlers. Factory and SimpleNft each have a
// wildcard handler whose `where` filters on their own addresses, and Factory
// one plain handler. Factory comes first: the mock source hangs its own,
// address-dependent registration on the chain's first contract.
let scenario = Scenario.make(
  ~configYaml=chainYaml(
    ~name="fetch-state-wildcard-partitions",
    ~contracts=`
      - name: Factory
        address: ["${factory0}", "${factory1}"]
        events:
          - event: "Register(string contractName, address contractAddress)"
          - event: "Transfer(address indexed from, address indexed to, uint256 value)"
      - name: Gravatar
        address: ["${gravatar2}", "${gravatar3}"]
        events:
          - event: "TestEvent()"
      - name: SimpleNft
        events:
          - event: "Transfer(address indexed from, address indexed to, uint256 value)"`,
  ),
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Factory", event: "Register" }, async () => {});
indexer.contractRegister({ contract: "Factory", event: "Register" }, async ({ event, context }) => {
  const { contractName, contractAddress } = event.params;
  if (contractName === "Factory") context.chain.Factory.add(contractAddress);
  if (contractName === "Gravatar") context.chain.Gravatar.add(contractAddress);
  if (contractName === "SimpleNft") context.chain.SimpleNft.add(contractAddress);
});

indexer.onEvent(
  {
    contract: "Factory",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => ({ params: { from: chain.Factory.addresses } }),
  },
  async () => {},
);
indexer.onEvent(
  {
    contract: "SimpleNft",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => ({ params: { from: chain.SimpleNft.addresses } }),
  },
  async () => {},
);

indexer.onEvent({ contract: "Gravatar", event: "TestEvent", wildcard: true }, async () => {});
indexer.onEvent({ contract: "Gravatar", event: "TestEvent", wildcard: true }, async () => {});
`,
)

let register = (~blockNumber, ~logIndex=0, contractName, contractAddress): MockSource.itemMock => {
  event: "Factory.Register",
  blockNumber,
  logIndex,
  srcAddress: factory0,
  params: dict{
    "contractName": contractName->(Utils.magic: string => unknown),
    "contractAddress": contractAddress->(Utils.magic: string => unknown),
  },
}

describe("Wildcard and address-filtered partitions", () => {
  scenario->Scenario.it(
    "fetches wildcard events without addresses, and no address of a contract with only wildcard events",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock.expectItemsQueries([{reply: LeavePending}])
      t.expect((
        sourceMock.pendingItemsQueries->summarize,
        sourceMock.pendingItemsQueries->summarizeSelections,
      )).toEqual((
        [
          {fromBlock: 0, toBlock: Bounded(800), addresses: []},
          {fromBlock: 0, toBlock: Bounded(800), addresses: [factory0, factory1]},
        ],
        [
          {
            dependsOnAddresses: false,
            events: ["Gravatar.TestEvent", "Gravatar.TestEvent"],
          },
          // A wildcard event filtered by addresses goes with the address queries.
          {
            dependsOnAddresses: true,
            events: [
              "Factory.Register",
              "Factory.Transfer",
              "SimpleNft.Transfer",
              "Factory.MockEvent",
              "Factory.MockEvent",
            ],
          },
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "groups registrations for an address-filtered contract like any other contract's",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock.expectItemsQueries([
        {reply: LeavePending},
        {
          reply: Respond({
            items: [
              register(~blockNumber=3, "Gravatar", gravatar4),
              register(~blockNumber=3, ~logIndex=1, "SimpleNft", simpleNft1),
              register(~blockNumber=3, ~logIndex=2, "SimpleNft", simpleNft2),
              register(~blockNumber=5, "SimpleNft", simpleNft3),
              register(~blockNumber=6, "Factory", factory5),
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      // Partition 1's next query goes out with its response; the
      // registrations land once the contractRegister run that follows ends.
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {reply: LeavePending},
        {fromBlock: 101, reply: LeavePending},
        {reply: LeavePending},
      ])
      t.expect(
        sourceMock.pendingItemsQueries->summarize,
        ~message="the Gravatar registration is fetched nowhere: its only events are wildcard",
      ).toEqual([
        {fromBlock: 0, toBlock: Bounded(800), addresses: []},
        {
          fromBlock: 101,
          toBlock: Bounded(800),
          addresses: [factory0, factory1],
        },
        {
          fromBlock: 3,
          toBlock: Bounded(800),
          addresses: [simpleNft1, simpleNft2, simpleNft3],
        },
        {fromBlock: 6, toBlock: Bounded(800), addresses: [factory5]},
      ])
    },
  )
})

describe("Partitions of address-filtered contracts", () => {
  let filtered = Scenario.make(
    ~configYaml=chainYaml(
      ~name="fetch-state-address-filtered-start-blocks",
      ~contracts=`
      - name: ContractA
        address: "${contractA}"
        events:
          - event: "Transfer(address indexed from, address indexed to, uint256 value)"
      - name: ContractB
        address: "${contractB}"
        start_block: 100
        events:
          - event: "Transfer(address indexed from, address indexed to, uint256 value)"`,
    ),
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  {
    contract: "ContractA",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => ({ params: { from: chain.ContractA.addresses } }),
  },
  async () => {},
);
indexer.onEvent(
  {
    contract: "ContractB",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => ({ params: { from: chain.ContractB.addresses } }),
  },
  async () => {},
);
`,
  )

  filtered->Scenario.it(
    "fetches address-filtered contracts with different start blocks in one partition",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock.expectItemsQueries([{reply: LeavePending}])
      t.expect((
        sourceMock.pendingItemsQueries->summarize,
        sourceMock.pendingItemsQueries->summarizeSelections,
      )).toEqual((
        [
          {
            fromBlock: 0,
            toBlock: Bounded(800),
            addresses: [contractA, contractB],
          },
        ],
        [
          {
            dependsOnAddresses: true,
            events: [
              "ContractA.Transfer",
              "ContractB.Transfer",
              "ContractA.MockEvent",
              "ContractA.MockEvent",
            ],
          },
        ],
      ))
    },
  )
})
