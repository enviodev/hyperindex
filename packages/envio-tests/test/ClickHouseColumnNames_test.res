open Vitest

// Postgres and ClickHouse each take their own `column_name_format`, so one
// renaming its columns leaves the other's as declared.

let configYaml = (~postgres, ~clickhouse) =>
  `
name: clickhouse-column-names
storage:
  postgres:
    default: true
    column_name_format: ${postgres}
  clickhouse:
    default: true
    column_name_format: ${clickhouse}
chains:
  - id: 1
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

let schema = `
type Token {
  id: ID!
  tokenId: Int!
}
`

let unsupported: array<Scenario.unsupported> = [
  {backend: #postgres, reason: "asserts against a ClickHouse server"},
]

type token = {id: string, tokenId: int}
type tokenOps = {set: token => unit}
type handlerContext = {@as("Token") token: tokenOps}

let setToken: MockSource.itemMock = {
  blockNumber: 1,
  logIndex: 0,
  handler: async args =>
    (args.context->(Utils.magic: Internal.handlerContext => handlerContext)).token.set({
      id: "1",
      tokenId: 7,
    }),
}

let columns = async (sql, ~pgSchema) => {
  let postgres: array<{
    "name": string,
  }> = await sql->Sql.queryForTests(
    `SELECT column_name::text AS "name" FROM information_schema.columns
     WHERE table_schema = $1 AND table_name = 'Token' ORDER BY ordinal_position;`,
    ~params=[pgSchema->(Utils.magic: string => unknown)],
  )
  let clickhouse = await TestClickHouse.query(
    `SELECT name FROM system.columns WHERE database = '${TestClickHouse.currentDatabase()}' AND table = 'Token' ORDER BY position FORMAT JSONEachRow`,
  )
  (
    postgres->Array.map(row => row["name"]),
    clickhouse
    ->String.trim
    ->String.split("\n")
    ->Array.map(line =>
      (line->JSON.parseOrThrow->(Utils.magic: JSON.t => {"name": string}))["name"]
    ),
  )
}

let writeAndRead = async (
  ~indexer: IndexerRunner.t,
  ~source: (int, ~index: int=?) => MockSource.t,
  ~sql,
) => {
  let source = source(1)
  source.resolveGetHeightOrThrow(100)
  await source.expectItemsQueries([
    {fromBlock: 1, toBlock: Unbounded, reply: Respond({items: [setToken]})},
  ])
  await indexer.getBatchWritePromise()
  await sql->columns(~pgSchema=indexer.pgSchema)
}

let isEntityColumn = name => name === "id" || name->String.toLowerCase->String.includes("token")

describe("Column names per storage", () => {
  Scenario.make(
    ~unsupported,
    ~schema,
    ~configYaml=configYaml(~postgres="snake_case", ~clickhouse="original"),
  )->Scenario.it("follow Postgres' format in Postgres only", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    await indexer.usePostgresSql(
      async sql => {
        let (postgres, clickhouse) = await writeAndRead(~indexer, ~source, ~sql)
        t.expect((postgres, clickhouse->Array.filter(isEntityColumn))).toEqual((
          ["id", "token_id"],
          ["id", "tokenId"],
        ))
      },
    )
  })

  Scenario.make(
    ~unsupported,
    ~schema,
    ~configYaml=configYaml(~postgres="original", ~clickhouse="snake_case"),
  )->Scenario.it("follow ClickHouse's format in ClickHouse only", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    await indexer.usePostgresSql(
      async sql => {
        let (postgres, clickhouse) = await writeAndRead(~indexer, ~source, ~sql)
        t.expect((postgres, clickhouse->Array.filter(isEntityColumn))).toEqual((
          ["id", "tokenId"],
          ["id", "token_id"],
        ))
      },
    )
  })
})

type readingContext = {
  @as("Token") token: {"set": token => unit, "get": string => promise<option<token>>},
}

describe("An entity kept in ClickHouse alone under renamed columns", () => {
  let loaded = ref(None)

  Scenario.make(
    ~unsupported,
    ~schema=`
type Token @storage(clickhouse: {}) {
  id: ID!
  tokenId: Int!
}
`,
    ~configYaml=configYaml(~postgres="original", ~clickhouse="snake_case"),
  )->Scenario.it("reads back as the schema names its fields", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(100)
    let context = (args: Internal.handlerArgs) =>
      args.context->(Utils.magic: Internal.handlerContext => readingContext)
    await source.expectItemsQueries([
      {
        fromBlock: 1,
        toBlock: Unbounded,
        reply: Respond({
          items: [
            {
              blockNumber: 1,
              logIndex: 0,
              handler: async args => (args->context).token["set"]({id: "1", tokenId: 7}),
            },
          ],
          latestFetchedBlockNumber: 1,
        }),
      },
    ])
    await indexer.getBatchWritePromise()
    // A fresh run holds nothing in memory, so the read is ClickHouse's.
    source.setAutoHeight(100)
    let restarted = await indexer.restart()
    await source.expectItemsQueries([
      {
        fromBlock: 2,
        toBlock: Unbounded,
        reply: Respond({
          items: [
            {
              blockNumber: 2,
              logIndex: 0,
              handler: async args => loaded := Some(await (args->context).token["get"]("1")),
            },
          ],
        }),
      },
    ])
    await restarted.getBatchWritePromise()

    t.expect(loaded.contents).toEqual(Some(Some({id: "1", tokenId: 7})))
  })
})
