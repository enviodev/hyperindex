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
          - event: "Write()"
          - event: "ReadBack()"
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
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "Write" }, async ({ context }) => {
  context.User.set({ id: "user-1" });
  context.Snapshot.set({ id: "1", transactionIndex: 5, tokenOwner_id: "user-1" });
});

indexer.onEvent({ contract: "Gravatar", event: "ReadBack" }, async ({ context }) => {
  const snapshot = await context.Snapshot.get("1");
  if (snapshot) {
    context.Snapshot.set({ ...snapshot, id: "got" });
  }
  const found = await context.Snapshot.getWhere({ transactionIndex: { _eq: 5 } });
  for (const snapshot of found) {
    context.Snapshot.set({ ...snapshot, id: "where" });
  }
});
`,
)

describe("Snake-case columns", () => {
  scenario->Scenario.it(
    "are written, kept in history and read back under the schema's field names",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{event: "Gravatar.Write", blockNumber: 1, logIndex: 0}],
            latestFetchedBlockNumber: 1,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart()
      await sourceMock.expectItemsQueries([
        {
          coversBlock: 2,
          reply: Respond({
            items: [{event: "Gravatar.ReadBack", blockNumber: 2, logIndex: 0}],
            latestFetchedBlockNumber: 2,
          }),
        },
      ])
      await restarted.getBatchWritePromise()
      await sourceMock.expectItemsQueries([
        {coversBlock: 3, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await restarted.waitUntilReady()

      let {sql, pgSchema} = restarted.pg
      let raw: array<{
        "id": string,
        "transaction_index": int,
        "token_owner_id": string,
      }> = await sql->Sql.queryForTests(
        `SELECT "id", "transaction_index", "token_owner_id" FROM "${pgSchema}"."Snapshot" ORDER BY "id";`,
      )
      let history: array<{
        "id": string,
        "transaction_index": int,
        "envio_change": string,
      }> = await sql->Sql.queryForTests(
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
