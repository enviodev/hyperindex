open Vitest

// https://github.com/enviodev/hyperindex/pull/1595#discussion_r3861606904
// A history table's name is truncated to Postgres' identifier limit with the
// entity's index appended. These two share the 47 characters that survive, and
// the first one's next character is the leading digit of the second one's
// index (1 and 11): without a boundary between name and index they would
// truncate onto one table, and each would read the other's history.

let first = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1AA"
let second = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2BB"

let scenario = Scenario.make(
  ~configYaml=`
name: long-history-names
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
type A0 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1AA {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C1 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C2 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C3 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C4 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C5 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C6 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C7 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C8 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1C9 {
  id: ID!
}

type BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2BB {
  id: ID!
}
`,
)

type named = {id: string}
type namedOps = {set: named => unit}

let setBoth: MockSource.itemMock = {
  blockNumber: 1,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => dict<namedOps>)
    (context->Dict.getUnsafe(first)).set({id: "first"})
    (context->Dict.getUnsafe(second)).set({id: "second"})
  },
}

let ids = (changes: array<Change.t<named>>) =>
  changes->Array.map(change =>
    switch change {
    | Set({entityId}) | Delete({entityId}) => entityId->(Utils.magic: EntityId.t => string)
    }
  )

describe("Two entities whose names truncate alike", () => {
  scenario->Scenario.it(
    "keep a history table each",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source, ~head=100)
      source.resolveGetItemsOrThrow([setBoth], ~latestFetchedBlockNumber=1)
      await indexer.getBatchWritePromise()

      let {sql, pgSchema} = indexer.pg
      let historyTables: array<{
        "name": string,
      }> = await sql->Sql.query(
        `SELECT table_name AS "name" FROM information_schema.tables
          WHERE table_schema = '${pgSchema}' AND table_name LIKE 'envio_history_BBB%'
          ORDER BY table_name`,
      )
      let historyTables =
        historyTables->Array.filter(
          table => table["name"]->String.endsWith("$1") || table["name"]->String.endsWith("$11"),
        )

      // The names are what make the collision real: indexes 1 and 11, both cut
      // to the identifier limit.
      t.expect((
        historyTables->Array.map(table => table["name"]),
        (await indexer.queryHistory(first))->ids,
        (await indexer.queryHistory(second))->ids,
      )).toEqual((
        [`envio_history_${"B"->String.repeat(46)}$11`, `envio_history_${"B"->String.repeat(47)}$1`],
        ["first"],
        ["second"],
      ))
    },
  )
})
