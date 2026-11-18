open Vitest
open ItemsQueryView.Summary

let gravatar = "0x1111111111111111111111111111111111111111"
let nftFactory = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let contractA1 = "0xa000000000000000000000000000000000000001"
let contractA2 = "0xa000000000000000000000000000000000000002"
let contractB = "0xb000000000000000000000000000000000000001"
let dynamic1 = "0x0000000000000000000000000000000000000001"
let dynamic2 = "0x0000000000000000000000000000000000000002"

let pendingQueries = async (sourceMock: MockSource.t) => {
  await sourceMock.expectItemsQueries([{reply: LeavePending}])
  sourceMock.pendingItemsQueries->summarize
}

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

let registeringItem = (
  ~blockNumber,
  ~logIndex=0,
  ~emitter,
  contractAddress,
): MockSource.itemMock => {
  event: `${emitter}.Register`,
  blockNumber,
  logIndex,
  params: dict{"contractAddress": contractAddress->(Utils.magic: string => unknown)},
}

// Registers `addresses` at block 5, carries every partition to block 100 so the
// registrations are persisted, and restarts: the restarted chain builds its
// partitions from the stored static and dynamic addresses together.
let restartWithRegistered = async (
  ~indexer: IndexerRunner.t,
  ~sourceMock: MockSource.t,
  ~emitter,
  ~otherStartingPartitionIds=[],
  ~partitionIdsToFinish,
  addresses,
) => {
  let finish = (partitionId): MockSource.expectedItemsQuery => {
    partitionId,
    reply: Respond({items: [], latestFetchedBlockNumber: 100}),
  }
  await sourceMock.expectItemsQueries(
    [
      (
        {
          partitionId: "0",
          fromBlock: 0,
          reply: Respond({
            items: addresses->Array.mapWithIndex((address, logIndex) =>
              registeringItem(~blockNumber=5, ~logIndex, ~emitter, address)
            ),
            latestFetchedBlockNumber: 100,
          }),
        }: MockSource.expectedItemsQuery
      ),
    ]->Array.concat(otherStartingPartitionIds->Array.map(finish)),
  )
  await sourceMock.expectItemsQueries(
    partitionIdsToFinish
    ->Array.map(finish)
    ->Array.concat(
      ["0"]
      ->Array.concat(otherStartingPartitionIds)
      ->Array.map((partitionId): MockSource.expectedItemsQuery => {
        partitionId,
        reply: LeavePending,
      }),
    ),
  )
  await indexer.waitUntilIdle()
  let _ = await indexer.restart()
  await sourceMock->pendingQueries
}

describe("Partitions a chain starts with", () => {
  let single = Scenario.make(
    ~configYaml=chainYaml(
      ~name="fetch-state-single-static",
      ~contracts=`
      - name: Gravatar
        address: "${gravatar}"
        events:
          - event: "TestEvent()"
      - name: NftFactory
        address: "${nftFactory}"
        events:
          - event: "TestEvent()"`,
    ),
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
`,
  )

  single->Scenario.it(
    "fetches a static address from the start block, and keeps a contract without handlers out of every query",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    async (~t, ~indexer, ~source) => {
      let queries = await source(1337)->pendingQueries
      t.expect(
        (
          queries,
          (await indexer.metric("envio_indexing_contract_addresses"))->Array.map(
            ({value, labels}) => (labels->Dict.get("contract"), value),
          ),
        ),
        ~message="the address without handlers is still counted as registered",
      ).toEqual((
        [{partitionId: "0", fromBlock: 0, toBlock: Bounded(800), addresses: [gravatar]}],
        [(Some("Gravatar"), "1"), (Some("NftFactory"), "1")],
      ))
    },
  )

  let nothingToFetch = Scenario.make(
    ~configYaml=chainYaml(
      ~name="fetch-state-nothing-to-fetch",
      ~contracts=`
      - name: Gravatar
        events:
          - event: "TestEvent()"`,
    ),
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
`,
  )

  Async.it("refuses to start a chain with nothing to fetch", async t => {
    let error = switch await nothingToFetch->Scenario.run(
      ~sources=[{chain: 1337, autoHeight: 1000}],
      async (~indexer as _, ~source as _) => (),
    ) {
    | () => None
    | exception JsExn(error) => error->JsExn.message->Option.map(IndexerRunner.stripLogsLink)
    }
    // The mock source's own registration on Gravatar is the second one.
    t.expect(error).toEqual(
      Some(
        "Invalid configuration: Nothing to fetch on chain 1337. addresses=0, onEventRegistrations=2, normalRegistrations=2. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
      ),
    )
  })
})

describe("Partitions a chain resumes with", () => {
  let sameContract = Scenario.make(
    ~configYaml=chainYaml(
      ~name="fetch-state-resume-same-contract",
      ~contracts=`
      - name: Gravatar
        address: "${gravatar}"
        events:
          - event: "Register(address contractAddress)"`,
    ),
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "Register" }, async () => {});
indexer.contractRegister({ contract: "Gravatar", event: "Register" }, async ({ event, context }) => {
  context.chain.Gravatar.add(event.params.contractAddress);
});
`,
  )

  sameContract->Scenario.it(
    "fetches static and dynamic addresses of one contract together up to maxAddrInPartition",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    ~maxAddrInPartition=2,
    async (~t, ~indexer, ~source) => {
      let queries = await restartWithRegistered(
        ~indexer,
        ~sourceMock=source(1337),
        ~emitter="Gravatar",
        ~partitionIdsToFinish=["1"],
        [dynamic1],
      )
      t.expect(queries).toEqual([
        {
          partitionId: "0",
          fromBlock: 101,
          toBlock: Bounded(800),
          addresses: [dynamic1, gravatar],
        },
      ])
    },
  )

  let otherContract = Scenario.make(
    ~configYaml=chainYaml(
      ~name="fetch-state-resume-other-contract",
      ~contracts=`
      - name: ContractA
        address: ["${contractA1}", "${contractA2}"]
        events:
          - event: "Register(address contractAddress)"
      - name: Gravatar
        events:
          - event: "TestEvent()"`,
    ),
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ContractA", event: "Register" }, async () => {});
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.contractRegister({ contract: "ContractA", event: "Register" }, async ({ event, context }) => {
  context.chain.Gravatar.add(event.params.contractAddress);
});
`,
  )

  otherContract->Scenario.it(
    "gives every address a partition of its own past maxAddrInPartition",
    ~sources=[{chain: 1337, autoHeight: 1000}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let queries = await restartWithRegistered(
        ~indexer,
        ~sourceMock=source(1337),
        ~emitter="ContractA",
        ~otherStartingPartitionIds=["1"],
        ~partitionIdsToFinish=["2", "3"],
        [dynamic1, dynamic2],
      )
      let query = (partitionId, address) => {
        partitionId,
        fromBlock: 101,
        toBlock: MockSource.Bounded(800),
        addresses: [address],
      }
      t.expect(queries).toEqual([
        query("0", contractA1),
        query("1", contractA2),
        query("2", dynamic1),
        query("3", dynamic2),
      ])
    },
  )
})

describe("Partitions of contracts with different start blocks", () => {
  let withContractBFrom = startBlock =>
    Scenario.make(
      ~configYaml=chainYaml(
        ~name=`fetch-state-start-blocks-${startBlock->Int.toString}`,
        ~contracts=`
      - name: ContractA
        address: "${contractA1}"
        events:
          - event: "TestEvent()"
      - name: ContractB
        address: "${contractB}"
        start_block: ${startBlock->Int.toString}
        events:
          - event: "TestEvent()"`,
      ),
      ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ContractA", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "ContractB", event: "TestEvent" }, async () => {});
`,
    )

  let closeStart = withContractBFrom(19_999)
  let farStart = withContractBFrom(20_002)

  closeStart->Scenario.it(
    "fetches a contract starting close to another in the same partition from the start",
    ~sources=[{chain: 1337, autoHeight: 100_000}],
    async (~t, ~indexer as _, ~source) => {
      t.expect(await source(1337)->pendingQueries).toEqual([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: Bounded(99_800),
          addresses: [contractA1, contractB],
        },
      ])
    },
  )

  farStart->Scenario.it(
    "fetches a contract starting far from another apart until the earlier one reaches its start block",
    ~sources=[{chain: 1337, autoHeight: 100_000}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      let beforeMerge = await sourceMock->pendingQueries
      await sourceMock.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: [], latestFetchedBlockNumber: 20_001})},
      ])
      let afterMerge = await sourceMock->pendingQueries
      t.expect((beforeMerge, afterMerge)).toEqual((
        [{partitionId: "0", fromBlock: 0, toBlock: Bounded(20_001), addresses: [contractA1]}],
        [
          {
            partitionId: "1",
            fromBlock: 20_002,
            toBlock: Bounded(99_800),
            addresses: [contractA1, contractB],
          },
        ],
      ))
    },
  )
})
