open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-load-metrics
storage:
  postgres:
    default: true
  clickhouse: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}

type Visit @storage(clickhouse: {}) {
  id: ID!
  value: String!
}
`,
  ~unsupported=[
    {
      backend: #postgres,
      reason: "the ClickHouse-only entity needs a ClickHouse database to write into",
    },
  ],
)

type row = {id: string, value: string}
type ops = {set: row => unit, get: string => promise<option<row>>}
type handlerContext = {
  @as("SimpleEntity") simpleEntity: ops,
  @as("Visit") visit: ops,
}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

describe("Storage load metrics with ClickHouse alongside Postgres", () => {
  scenario->Scenario.it(
    "labels each entity's loads with the store that serves them",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.simpleEntity.set({id: "1", value: "pg"})
              context.visit.set({id: "1", value: "ch"})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let resumed = await indexer.restart()
      source.resolveGetHeightOrThrow(20)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 15,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              let _ = await context.simpleEntity.get("1")
              let _ = await context.visit.get("1")
            },
          },
        ],
        ~latestFetchedBlockNumber=20,
      )
      await resumed.getBatchWritePromise()

      t.expect(await resumed.metric("envio_storage_load_total")).toEqual([
        {value: "1", labels: dict{"operation": "SimpleEntity.get", "storage": "postgres"}},
        {value: "1", labels: dict{"operation": "Visit.get", "storage": "clickhouse"}},
      ])
    },
  )
})
