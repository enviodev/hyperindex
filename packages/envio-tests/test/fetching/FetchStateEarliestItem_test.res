open Vitest

let staticAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"
let secondAddress = "0x1111111111111111111111111111111111111111"
let registeredAddress = "0x2222222222222222222222222222222222222222"

// The head sits far past where each scenario fetches, so a registered address
// gets a partition of its own rather than the address-free one used near it.

let scenarioWith = (~addresses, ~extra="") =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-earliest-item
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0${extra}
    contracts:
      - name: Gravatar
        address:
${addresses->Array.map(address => `          - "${address}"`)->Array.join("\n")}
        events:
          - event: "TestEvent(address[] addresses)"
`,
    ~schema=`
type Run {
  id: ID!
  order: String!
}
`,
    ~handlers=`
import { indexer } from "envio";

type RunStore = {
  get: (id: string) => Promise<{ order: string } | undefined>;
  set: (run: { id: string; order: string }) => void;
};

const record = async (context: { Run: RunStore }, label: string) => {
  const run = await context.Run.get("run");
  context.Run.set({ id: "run", order: run ? run.order + " " + label : label });
};

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  await record(context, \`\${event.block.number}:\${event.logIndex}\`);
});

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  for (const address of event.params.addresses) {
    context.chain.Gravatar.add(address);
  }
});
`,
  )

type run = {id: string, order: string}

let event = (~blockNumber, ~logIndex=0, ~registers=[]): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber,
  logIndex,
  params: dict{"addresses": registers->(Utils.magic: array<string> => unknown)},
}

let processedOrder = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Run"): array<run>)->Array.map(({order}) => order)

let singleStatic = scenarioWith(~addresses=[staticAddress])

describe("FetchState earliest processable item over the indexer loop", () => {
  singleStatic->Scenario.it(
    "Processes events below a registration's block while the new partition catches up",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          reply: Respond({
            items: [
              event(~blockNumber=6, ~logIndex=2),
              event(~blockNumber=3, ~registers=[registeredAddress]),
              event(~blockNumber=2, ~logIndex=1),
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {reply: LeavePending},
        {reply: LeavePending},
      ])
      await indexer.getBatchWritePromise()
      let beforeCatchUp = await processedOrder(indexer)
      await sync.expectItemsQueries([
        {fromBlock: 3, reply: Respond({items: [], latestFetchedBlockNumber: 10})},
        {reply: LeavePending},
      ])
      await indexer.getBatchWritePromise()
      t.expect((beforeCatchUp, await processedOrder(indexer))).toEqual((["2:1"], ["2:1 3:0 6:2"]))
    },
  )

  singleStatic->Scenario.it(
    "Holds back events at a registration's block until the new partition fetches it",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          reply: Respond({
            items: [
              event(~blockNumber=6, ~logIndex=1),
              event(~blockNumber=5),
              event(~blockNumber=2, ~logIndex=1, ~registers=[registeredAddress]),
            ],
            latestFetchedBlockNumber: 500,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {reply: LeavePending},
        {reply: LeavePending},
      ])
      await indexer.advanceTime(1000)
      let beforeCatchUp = await processedOrder(indexer)
      await sync.expectItemsQueries([
        {
          fromBlock: 2,
          reply: Respond({items: [], latestFetchedBlockNumber: 500}),
        },
        {reply: LeavePending},
      ])
      await indexer.getBatchWritePromise()
      t.expect((beforeCatchUp, await processedOrder(indexer))).toEqual(([], ["2:1 5:0 6:1"]))
    },
  )

  scenarioWith(
    ~addresses=[staticAddress, secondAddress],
  )->Scenario.it(
    "Processes nothing while another partition hasn't fetched the start block",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          reply: Respond({
            items: [event(~blockNumber=0, ~logIndex=1)],
            latestFetchedBlockNumber: 1,
          }),
        },
        {reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {reply: LeavePending},
        {reply: LeavePending},
      ])
      await indexer.advanceTime(1000)
      let whileBehind = await processedOrder(indexer)
      await sync.expectItemsQueries([
        {fromBlock: 0, reply: Respond({items: [], latestFetchedBlockNumber: 1})},
        {reply: LeavePending},
      ])
      await indexer.getBatchWritePromise()
      t.expect((whileBehind, await processedOrder(indexer))).toEqual(([], ["0:1"]))
    },
  )

  let exited = ref(false)
  scenarioWith(~addresses=[staticAddress], ~extra="\n    end_block: 0")->Scenario.it(
    "Indexes a chain whose end block is its start block, processing what it fetched there",
    ~sources=[{chain: 1337}],
    ~onExit=() => exited := true,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Bounded(0),
          reply: Respond({items: [event(~blockNumber=0)]}),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.advanceTime(10_000)
      t.expect((await processedOrder(indexer), exited.contents)).toEqual((["0:0"], true))
    },
  )

  Async.it("Refuses a chain whose end block is below its start block", async t => {
    let failure = try {
      let _ = Scenario.make(
        ~configYaml=`
name: fetch-state-earliest-item-inactive
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 10
    end_block: 9
    contracts:
      - name: Gravatar
        address: "${staticAddress}"
        events:
          - event: "TestEvent()"
`,
      )
      None
    } catch {
    | JsExn(exn) => exn->JsExn.message
    }
    t.expect(failure).toEqual(
      Some(
        "The config has an end_block smaller than start_block for chain 1337. end_block must be greater than or equal to start_block.",
      ),
    )
  })
})
