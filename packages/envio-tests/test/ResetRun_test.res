open Vitest

// `envio dev -r` drops the schema and builds it again, enums included, and the
// handlers of the run after it read and write against the new one.

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
          - event: "TestEvent()"
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
)

type counter = {id: string, status: string, seen: int}
type counterOps = {
  set: counter => unit,
  get: string => promise<option<counter>>,
  getWhere: {"status": {"_eq": string}} => promise<array<counter>>,
}
type handlerContext = {@as("Counter") counter: counterOps}

// Bumps the counter it finds, by id and by status, so a read that came back
// wrong shows in what is written.
let bump = (~block, ~status): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    let byId = await context.counter.get("1")
    let byStatus = await context.counter.getWhere({"status": {"_eq": status}})
    context.counter.set({
      id: "1",
      status,
      seen: byId->Option.mapOr(0, counter => counter.seen) + byStatus->Array.length + 1,
    })
  },
}

describe("A reset run", () => {
  scenario->Scenario.it(
    "starts from an empty schema and reads back what it writes",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source, ~head=100)
      source.resolveGetItemsOrThrow(
        [bump(~block=1, ~status="PENDING")],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()
      let before: array<counter> = await indexer.query("Counter")

      source.setAutoHeight(100)
      let reset = await indexer.restart(~reset=true, ())
      let afterReset: array<counter> = await reset.query("Counter")
      source.resolveGetItemsOrThrow(
        [bump(~block=1, ~status="ACTIVE"), bump(~block=2, ~status="ACTIVE")],
        ~latestFetchedBlockNumber=2,
      )
      await reset.getBatchWritePromise()

      t.expect((before, afterReset, (await reset.query("Counter"): array<counter>))).toEqual((
        [{id: "1", status: "PENDING", seen: 1}],
        [],
        [{id: "1", status: "ACTIVE", seen: 3}],
      ))
    },
  )
})
