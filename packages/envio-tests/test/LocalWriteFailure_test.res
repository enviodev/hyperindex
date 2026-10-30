open Vitest

// A batch write can fail before Postgres sees anything: a value the staging
// buffer refuses is caught in JavaScript. The rest of the batch — the
// checkpoint, the chain's progress — must not commit without it, or the
// indexer resumes past entities it never wrote.

let scenario = Scenario.make(
  ~configYaml=`
name: local-write-failure
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
type Tally {
  id: ID!
  count: Float!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ context }) => {
  // No column holds NaN, and the staging buffer is what says so.
  context.Tally.set({ id: "1", count: NaN });
});
`,
)

describe("A batch whose write fails in JavaScript", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "commits none of the rest of the batch",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Unbounded,
          reply: Respond({
            items: [{event: "Gravatar.TestEvent", blockNumber: 1, logIndex: 0}],
          }),
        },
      ])
      let failure = await refusal.awaitRefusalReason()

      let tallies: array<unknown> = await indexer.query("Tally")

      t.expect((
        failure,
        tallies,
        await indexer.queryCheckpoints(),
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
      )).toEqual((
        Some(
          "NaN is not a finite number, so it cannot be stored in the `count` column. Store a finite number, or keep it out of the entity.",
        ),
        // Neither the entity nor anything written beside it.
        [],
        [],
        [-1],
      ))
    },
  )
})
