open Vitest

// Reproduction for https://github.com/enviodev/hyperindex/issues/1242
//
// On startup the indexer loads every registered dynamic contract for a chain
// through InternalTable.Chains.getInitialState, which aggregates the whole
// envio_addresses table into a single json column with json_agg. With enough
// dynamic contracts that aggregated value exceeds V8's max string length
// (0x1fffffe8), and postgres.js throws ERR_STRING_TOO_LONG while decoding the
// row — the indexer can never resume.
//
// Each row here carries a 5MB contract_name so ~120 rows already push the
// aggregate past the limit. repeat('x', ...) is highly compressible, so the
// table stays tiny on disk while the decoded json string blows past the cap.
describe("Dynamic contracts startup size", () => {
  Async.it(
    "getInitialState loads all dynamic contracts when the aggregate exceeds the V8 string limit",
    async t => {
      let sourceMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let _indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock.source]),
          },
        ],
      )

      let sql = PgStorage.makeClient()
      let pgSchema = Env.Db.publicSchema

      let chainId = 1337
      let rowCount = 120
      let contractNameLength = 5_000_000

      let _ = await sql->Postgres.unsafe(
        `INSERT INTO "${pgSchema}"."${Config.EnvioAddresses.name}" ("id", "chain_id", "registration_block", "registration_log_index", "contract_name")
SELECT '${chainId->Int.toString}-0x' || lpad(to_hex(g), 40, '0'), ${chainId->Int.toString}, 0, -1, repeat('x', ${contractNameLength->Int.toString})
FROM generate_series(1, ${rowCount->Int.toString}) AS g;`,
      )

      let initialStates = await InternalTable.Chains.getInitialState(sql, ~pgSchema)
      let chainState = initialStates->Array.find(state => state.id === chainId)->Option.getOrThrow

      t.expect(
        chainState.indexingAddresses
        ->Array.filter(address => address.contractName->String.length === contractNameLength)
        ->Array.length,
        ~message=`All registered dynamic contracts should load even when the aggregated json exceeds the V8 string limit`,
      ).toBe(rowCount)
    },
    ~timeout=120_000,
  )
})
