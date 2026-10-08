open Vitest

// A batch the server refuses part of. Every write in it shares one
// transaction, so the entity it could store, the history row, the checkpoint
// and the chain's progress must all be missing afterwards, and a restarted
// indexer has to pick up from the last batch that did commit.

let scenario = Scenario.make(
  ~configYaml=`
name: storage-write-refusal
save_full_history: true
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
  count: Int!
}
`,
)

type tally = {id: string, count: int}
type tallyOps = {set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let setTally = (~block, ~logIndex=0, ~id, ~count): MockSource.itemMock => {
  blockNumber: block,
  logIndex,
  handler: async args =>
    (args.context->(Utils.magic: Internal.handlerContext => handlerContext)).tally.set({id, count}),
}

// Past what an `integer` column holds. JavaScript has no trouble with it, so
// the refusal comes from the server.
let tooLarge = 2147483648.->(Utils.magic: float => int)

type stored = {tallies: array<tally>, history: int, checkpoints: string, progress: array<int>}

let read = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let tallies: array<tally> = await indexer.query("Tally")
  let history: array<Change.t<tally>> = await indexer.queryHistory("Tally")
  let checkpoints: array<{
    "count": string,
  }> = await sql->Sql.query(
    `SELECT count(*)::text AS "count" FROM "${pgSchema}"."envio_checkpoints";`,
  )
  let progress: array<{
    "progress_block": int,
  }> = await sql->Sql.query(`SELECT "progress_block" FROM "${pgSchema}"."envio_chains";`)
  {
    tallies: tallies->Array.toSorted((a, b) => String.compare(a.id, b.id)),
    history: history->Array.length,
    checkpoints: (checkpoints->Array.getUnsafe(0))["count"],
    progress: progress->Array.map(row => row["progress_block"]),
  }
}

describe("A batch the server refuses", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "commits nothing from it, and a restart resumes after the last good batch",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow(
        [setTally(~block=1, ~id="kept", ~count=1)],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()
      let committed = await read(indexer)

      sourceMock.resolveGetItemsOrThrow(
        [
          setTally(~block=2, ~id="kept", ~count=2),
          setTally(~block=2, ~logIndex=1, ~id="refused", ~count=tooLarge),
        ],
        ~filter=MockSource.coveringBlock(2),
        ~latestFetchedBlockNumber=2,
      )
      let reason = await refusal.awaitRefusalReason()
      let afterRefusal = await read(indexer)

      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart()
      sourceMock.resolveGetItemsOrThrow(
        [setTally(~block=2, ~id="kept", ~count=2)],
        ~filter=MockSource.coveringBlock(2),
        ~latestFetchedBlockNumber=2,
      )
      await restarted.getBatchWritePromise()
      let resumed = await read(restarted)

      t.expect((
        reason->Option.map(reason => reason->String.includes("out of range")),
        afterRefusal,
        resumed,
      )).toEqual((
        Some(true),
        committed,
        {tallies: [{id: "kept", count: 2}], history: 2, checkpoints: "2", progress: [2]},
      ))
    },
  )
})
