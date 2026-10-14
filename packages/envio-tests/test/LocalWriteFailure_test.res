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
)

type tally = {id: string, count: float}
type tallyOps = {set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

describe("A batch whose write fails in JavaScript", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "commits none of the rest of the batch",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 1,
            logIndex: 0,
            // No column holds NaN, and the staging buffer is what says so.
            handler: async args =>
              (args->contextOf).tally.set({id: "1", count: Float.Constants.nan}),
          },
        ],
        ~latestFetchedBlockNumber=1,
      )
      let failure = await refusal.awaitRefusalReason()

      let tallies: array<tally> = await indexer.query("Tally")

      t.expect((
        failure,
        [tallies->Array.length->Int.toString],
        [(await indexer.queryCheckpoints())->Array.length->Int.toString],
        (await indexer.queryChains())->Array.map(row => row.progressBlock),
      )).toEqual((
        Some(
          "NaN is not a finite number, so it cannot be stored in the `count` column. Store a finite number, or keep it out of the entity.",
        ),
        // Neither the entity nor anything written beside it.
        ["0"],
        ["0"],
        [-1],
      ))
    },
  )
})
