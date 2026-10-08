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

describe("A chain metadata snapshot from before the indexer was ready", () => {
  let lastBeforeReady = ref(None)
  let replayed = ref(false)
  scenario->Scenario.it(
    "lands after the ready stamp without clearing it",
    ~sources=[{chain: 1337}],
    ~mapStorage=storage => {
      ...storage,
      setChainMeta: meta => {
        if !replayed.contents {
          lastBeforeReady := Some(meta)
        }
        storage.setChainMeta(meta)
      },
      finalizeBackfill: async (~entities, ~chainIds, ~readyAt) => {
        await storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
        switch lastBeforeReady.contents {
        | Some(meta) =>
          replayed := true
          let _ = await storage.setChainMeta(meta)
        | None => ()
        }
      },
    },
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect((replayed.contents, await readyAt(indexer))).toEqual((true, [true]))
    },
  )
})
