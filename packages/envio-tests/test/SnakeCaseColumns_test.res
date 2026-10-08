open Vitest

// `column_name_format: snake_case` renames the columns while handlers keep the
// schema's field names, so every path between the two has to translate: the
// write, the history, the reads a restarted indexer's handlers make, and the
// indexes the schema promises.

let scenario = Scenario.make(
  ~configYaml=`
name: snake-case-columns
save_full_history: true
storage:
  postgres:
    column_name_format: snake_case
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
type Snapshot {
  id: ID!
  transactionIndex: Int! @index
  tokenOwner: User!
}

type User {
  id: ID!
}
`,
)

type snapshot = {id: string, transactionIndex: int, tokenOwner_id: string}
type user = {id: string}
type snapshotOps = {
  set: snapshot => unit,
  get: string => promise<option<snapshot>>,
  getWhere: {"transactionIndex": {"_eq": int}} => promise<array<snapshot>>,
}
type userOps = {set: user => unit}
type handlerContext = {@as("Snapshot") snapshot: snapshotOps, @as("User") user: userOps}

let at = (~block, handler: handlerContext => promise<unit>): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await args.context->(Utils.magic: Internal.handlerContext => handlerContext)->handler,
}

describe("Snake-case columns", () => {
  scenario->Scenario.it(
    "are written, kept in history and read back under the schema's field names",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow(
        [
          at(
            ~block=1,
            async context => {
              context.user.set({id: "user-1"})
              context.snapshot.set({id: "1", transactionIndex: 5, tokenOwner_id: "user-1"})
            },
          ),
        ],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()

      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart()
      sourceMock.resolveGetItemsOrThrow(
        [
          at(
            ~block=2,
            async context => {
              switch await context.snapshot.get("1") {
              | Some(snapshot) => context.snapshot.set({...snapshot, id: "got"})
              | None => ()
              }
              let found = await context.snapshot.getWhere({"transactionIndex": {"_eq": 5}})
              found->Array.forEach(snapshot => context.snapshot.set({...snapshot, id: "where"}))
            },
          ),
        ],
        ~filter=MockSource.coveringBlock(2),
        ~latestFetchedBlockNumber=2,
      )
      await restarted.getBatchWritePromise()
      await MockSource.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(3),
        ~latestFetchedBlockNumber=100,
      )
      await restarted.waitUntilReady()

      let {sql, pgSchema} = restarted.pg
      let raw: array<{
        "id": string,
        "transaction_index": int,
        "token_owner_id": string,
      }> = await sql->Sql.query(
        `SELECT "id", "transaction_index", "token_owner_id" FROM "${pgSchema}"."Snapshot" ORDER BY "id";`,
      )
      let history: array<{
        "id": string,
        "transaction_index": int,
        "envio_change": string,
      }> = await sql->Sql.query(
        `SELECT "id", "transaction_index", "envio_change"::text FROM "${pgSchema}"."envio_history_Snapshot" ORDER BY "id";`,
      )

      let indexed =
        (await sql->PgCatalog.indexes(~pgSchema))
        ->Array.filter(index => index.tableName === "Snapshot" && !index.isUnique)
        ->Array.map(index => index.columns)

      t.expect((raw, history, indexed)).toEqual((
        [
          {"id": "1", "transaction_index": 5, "token_owner_id": "user-1"},
          {"id": "got", "transaction_index": 5, "token_owner_id": "user-1"},
          {"id": "where", "transaction_index": 5, "token_owner_id": "user-1"},
        ],
        [
          {"id": "1", "transaction_index": 5, "envio_change": "SET"},
          {"id": "got", "transaction_index": 5, "envio_change": "SET"},
          {"id": "where", "transaction_index": 5, "envio_change": "SET"},
        ],
        // The schema's `@index` lands on the renamed column.
        [["transaction_index"]],
      ))
    },
  )
})
