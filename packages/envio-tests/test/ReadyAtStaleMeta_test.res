open Vitest

// `ready_at` is committed by the finalization, while chain metadata is written
// on a throttle of its own, outside the batch the finalization flushes. A
// snapshot taken before the stamp can reach the database after it, and must
// not clear it.

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: ready-at-stale-meta
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
}
`,
)

let readyAt = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "ready_at": Null.t<Date.t>,
  }> = await sql->Sql.query(`SELECT "ready_at" FROM "${pgSchema}"."envio_chains";`)
  rows->Array.map(row => row["ready_at"]->Null.toOption->Option.isSome)
}

type replay = {
  mutable beforeReady: option<dict<InternalTable.Chains.metaFields>>,
  mutable done: bool,
}

describe("A chain metadata snapshot from before the indexer was ready", () => {
  let replay = ref({beforeReady: None, done: false})
  scenario->Scenario.it(
    "lands after the ready stamp without clearing it",
    ~sources=[{chain: 1337}],
    ~mapStorage=storage => {
      let state = {beforeReady: None, done: false}
      replay := state
      {
        ...storage,
        // Once the snapshot is replayed nothing else is written, so a later
        // write that stamps `ready_at` again can't hide one that cleared it.
        setChainMeta: meta =>
          if state.done {
            Promise.resolve(()->(Utils.magic: unit => unknown))
          } else {
            state.beforeReady = Some(meta)
            storage.setChainMeta(meta)
          },
        finalizeBackfill: async (~entities, ~chainIds, ~readyAt) => {
          await storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
          switch state.beforeReady {
          | Some(meta) =>
            state.done = true
            let _ = await storage.setChainMeta(meta)
          | None => ()
          }
        },
      }
    },
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect((replay.contents.done, await readyAt(indexer))).toEqual((true, [true]))
    },
  )
})
