open Vitest

// A build blocks writes to its table, so the logs are where an operator learns
// what the indexes are doing.

let configYaml = `
name: index-logs
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
`

let noIndexes = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema=`
type Tally {
  id: ID!
}
`,
)

let indexed = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema=`
type Token {
  id: ID!
  owner: String! @index
}
`,
)

// Index events are logged by the storage; the indexer's own "building
// database indexes" line is the phase it enters either way.
let fromStorage = (entry: IndexerRunner.logEntry) =>
  entry.params->Dict.get("storage") === Some(JSON.String("postgres"))

describe("Index logs", () => {
  noIndexes->Scenario.it(
    "say nothing for a schema that declares no indexes",
    ~sources=[{chain: 1337}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()
      await indexer.waitUntilIdle()
      // Index events cross from the addon's threads on a queue of their own;
      // nothing marks the end of one that never comes, so this is a lower bound.
      await Utils.delay(10)

      t.expect(indexer.logs()->Array.filter(fromStorage)->Array.map(entry => entry.msg)).toEqual([])
    },
  )

  // The column the index is on is gone, so restoring it on the next start
  // fails on the server.
  indexed->Scenario.it(
    "carry the server's code when a build fails",
    ~sources=[{chain: 1337}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()
      let {sql, pgSchema} = indexer.pg
      let _ = await sql->Sql.queryForTests(`ALTER TABLE "${pgSchema}"."Token" DROP COLUMN "owner";`)

      source.setAutoHeight(100)
      let restarted = await indexer.restart()
      let failed = () =>
        restarted.logs()->Array.filter(entry => entry.params->Dict.get("code")->Option.isSome)
      await Scenario.waitUntil(
        () => failed()->Utils.Array.notEmpty,
        ~message="the failed build to be logged",
      )

      t.expect(failed()->Array.map(entry => (entry.msg, entry.params->Dict.get("code")))).toEqual([
        (
          `Failed to restore the schema index "Token_owner_9t23tg2g16". Queries relying on it run unindexed until the next restart.`,
          Some(JSON.String("42703")),
        ),
      ])
    },
  )
})
