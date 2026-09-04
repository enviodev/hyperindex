open Vitest

// Reproduction for https://github.com/enviodev/hyperindex/issues/1242
//
// On startup the indexer loads every registered address for a chain through
// InternalTable.Chains.getInitialState. Aggregating the whole envio_addresses
// table into one json column (what it used to do) blows past V8's max string
// length once a chain has enough addresses, and postgres.js throws
// ERR_STRING_TOO_LONG while decoding the row — the indexer can never resume.
// Reading plain rows and grouping them in JS is what keeps that from
// happening.
//
// Skipped by default: crossing the limit takes enough rows to be too slow for
// every CI run. Run it manually to guard the fix for #1242.
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
)

describe("Dynamic contracts startup size", () => {
  Async.it_skip(
    "getInitialState loads all dynamic contracts when the aggregate exceeds the V8 string limit",
    async t => {
      await scenario->Scenario.run(
        ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
        async (~indexer, ~source as _) => {
          let {sql, pgSchema} = indexer.pg

          let chainId = 1337->ChainId.fromInt
          let rowCount = 30_000_000

          let _ = await sql->Postgres.unsafe(
            `INSERT INTO "${pgSchema}"."${InternalTable.EnvioAddresses.name}" ("chain_id", "address", "contract_id", "registration_block")
  SELECT ${chainId->ChainId.toString}, decode(lpad(to_hex(g), 40, '0'), 'hex'), 0, 0
  FROM generate_series(1, ${rowCount->Int.toString}) AS g
  ON CONFLICT DO NOTHING;`,
          )

          let initialStates = await InternalTable.Chains.getInitialState(sql, ~pgSchema)
          let chainState =
            initialStates->Array.find(state => state.id === chainId)->Option.getOrThrow

          t.expect(
            chainState.addressRows.contractIds->Array.length,
            ~message=`Every stored address should load, however many a chain has`,
          ).toBeGreaterThanOrEqual(rowCount)
        },
      )
    },
  )
})
