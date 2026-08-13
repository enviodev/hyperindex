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
// Skipped by default: it pushes ~600MB through Postgres to cross the V8 string
// limit, which is too slow/heavy for every CI run. Run it manually to guard the
// fix for #1242.
let scenario = Scenario.make(
  ~configYaml=`
name: dynamic-contracts-startup-size
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
type Gravatar {
  id: ID!
  owner: String!
}
`,
  ~unsupported=[
    {backend: #memory, reason: "reproduces a Postgres json_agg decoding limit"},
  ],
)

describe("Dynamic contracts startup size", () => {
  Async.it_skip(
    "getInitialState loads all dynamic contracts when the aggregate exceeds the V8 string limit",
    async t => {
      await scenario->Scenario.run(
        ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
        async (~indexer, ~source as _) => {
          let {sql, pgSchema} = indexer->IndexerRunner.pgOrThrow

          let chainId = 1337->ChainId.fromInt
          let rowCount = 120
          let contractNameLength = 5_000_000

          let _ = await sql->Postgres.unsafe(
            `INSERT INTO "${pgSchema}"."${Config.EnvioAddresses.name}" ("id", "chain_id", "registration_block", "registration_log_index", "contract_name")
  SELECT '${chainId->ChainId.toString}-0x' || lpad(to_hex(g), 40, '0'), ${chainId->ChainId.toString}, 0, -1, repeat('x', ${contractNameLength->Int.toString})
  FROM generate_series(1, ${rowCount->Int.toString}) AS g;`,
          )

          let initialStates = await InternalTable.Chains.getInitialState(sql, ~pgSchema)
          let chainState =
            initialStates->Array.find(state => state.id === chainId)->Option.getOrThrow

          t.expect(
            chainState.indexingAddresses
            ->Array.filter(address => address.contractName->String.length === contractNameLength)
            ->Array.length,
            ~message=`All registered dynamic contracts should load even when the aggregated json exceeds the V8 string limit`,
          ).toBe(rowCount)
        },
      )
    },
  )
})
