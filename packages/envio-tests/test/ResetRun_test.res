open Vitest

// `envio dev -r` drops the schema and builds it again, enums included, and the
// handlers of the run after it read and write against the new one. A storage
// reused across its own reset is pinned in the addon's live tests: no command
// does that in one process.

let scenario = Scenario.make(
  ~configYaml=`
name: reset-run
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent(string status)"
`,
  ~schema=`
enum Status {
  PENDING
  ACTIVE
}

type Counter {
  id: ID!
  status: Status!
  seen: Int!
}
`,
  // Bumps the counter it finds, by id and by status, so a read that came back
  // wrong shows in what is written.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  const status = event.params.status as "PENDING" | "ACTIVE";
  const byId = await context.Counter.get("1");
  const byStatus = await context.Counter.getWhere({ status: { _eq: status } });
  context.Counter.set({
    id: "1",
    status,
    seen: (byId?.seen ?? 0) + byStatus.length + 1,
  });
});
`,
)

type counter = {id: string, status: string, seen: int}

let bump = (~block, ~status): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber: block,
  logIndex: 0,
  params: dict{"status": status->(Utils.magic: string => unknown)},
}

describe("A reset run", () => {
  scenario->Scenario.it(
    "starts from an empty schema and reads back what it writes",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Unbounded,
          reply: Respond({items: [bump(~block=1, ~status="PENDING")]}),
        },
      ])
      await indexer.getBatchWritePromise()
      let before: array<counter> = await indexer.query("Counter")

      source.setAutoHeight(100)
      let reset = await indexer.restart(~reset=true, ())
      let afterReset: array<counter> = await reset.query("Counter")
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Unbounded,
          reply: Respond({
            items: [bump(~block=1, ~status="ACTIVE"), bump(~block=2, ~status="ACTIVE")],
            latestFetchedBlockNumber: 2,
          }),
        },
      ])
      await reset.getBatchWritePromise()

      t.expect((before, afterReset, (await reset.query("Counter"): array<counter>))).toEqual((
        [{id: "1", status: "PENDING", seen: 1}],
        [],
        [{id: "1", status: "ACTIVE", seen: 3}],
      ))
    },
  )
})
