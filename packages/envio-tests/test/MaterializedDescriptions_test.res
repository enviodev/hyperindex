open Vitest

// `_description` rides the generated GraphQL schema, so it ends up wherever an
// entity field's description already goes — the Postgres column comment, and
// through it the Hasura console and introspection.
let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: described-tables
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  accounts:
    from: evm.events
    select:
      id: params.to
      balance:
        _sum: params.value
        _description: "Everything this account has received"
      # A plain path can't carry a sibling key, so \`_value\` gives it one.
      last_sender:
        _value: params.from
        _description: "Who sent the most recent transfer"
      undescribed: params.value
`,
)

// Nothing applies these today: a table isn't tracked in Hasura, which is the
// only thing that turns a column config into a Postgres comment. The mapping is
// pinned so the descriptions are ready if a table is served again.
describe("_description", () => {
  it("Becomes the column comment, and only on the fields that have one", t => {
    let entityConfig =
      config.entitiesByTableName->Dict.valuesToArray
      ->Array.find((e: Internal.entityConfig) => e.table.tableName === "accounts")
      ->Option.getOrThrow
    t.expect(
      entityConfig.table
      ->Hasura.makeColumnConfigs
      ->(Utils.magic: dict<Hasura.columnConfig> => JSON.t),
    ).toEqual(
      {
        "balance": {"comment": "Everything this account has received"},
        "last_sender": {"comment": "Who sent the most recent transfer"},
      }->(Utils.magic: 'expected => JSON.t),
    )
  })
})
