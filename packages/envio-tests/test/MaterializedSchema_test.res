open Vitest

// What a `tables:` config turns into before any event is processed: the column
// types inferred from the ABI, the storage each table lands in, and the extra
// block/transaction fields the selected paths make the indexer fetch.
let parse = (~schema=?, configYaml) =>
  InternalTestIndexer.fromUserApi(~schema?, ~configYaml).config

let describeColumns = (config: Config.t, table) =>
  (config.entitiesByTableName->Dict.getUnsafe(table)).table.fields
  ->Array.filterMap(field =>
    switch field {
    | Table.Field({isChainId: true}) => None
    | Table.Field({fieldName, fieldType, isArray, isNullable, linkedEntity}) =>
      let base = switch fieldType {
      | String => "String"
      | Boolean => "Boolean"
      | Int32 => "Int"
      | Number => "Float"
      | BigInt(_) => "BigInt"
      | BigDecimal(_) => "BigDecimal"
      | Json => "Json"
      | other => (other->Utils.magic: string)
      }
      let base = switch linkedEntity {
      | Some(target) => `${base} -> ${target}`
      | None => base
      }
      Some((fieldName, `${isArray ? `[${base}]` : base}${isNullable ? "" : "!"}`))
    | Table.DerivedFrom({fieldName, derivedFromEntity}) =>
      Some((fieldName, `derivedFrom ${derivedFromEntity}`))
    }
  )

// Params are typed by the shared ABI mapping, so every shape a contract import
// can produce is selectable into a column.
describe("Column types inferred from the ABI", () => {
  it("Types every param shape", t => {
    let config = parse(`
name: abi-shapes
disable_default_cross_chain: true
contracts:
  - name: Shapes
    events:
      - event: "Many(address a, bool b, uint8 c, int256 d, uint256 e, bytes f, bytes32 g, string h, uint256[] i, address[2] j, (uint256 x, address y) k, uint8[][] l, (uint256 x)[] m)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Shapes
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  shapes:
    from: evm.events
    select:
      id: params.a
      bool_field: params.b
      small_uint: params.c
      signed: params.d
      big_uint: params.e
      bytes_field: params.f
      fixed_bytes: params.g
      string_field: params.h
      uint_list: params.i
      address_list: params.j
      tuple_member: params.k.x
      nested_list: params.l
      tuple_list: params.m
`)
    t.expect(config->describeColumns("shapes")).toEqual([
      ("id", "String!"),
      ("bool_field", "Boolean!"),
      ("small_uint", "BigInt!"),
      ("signed", "BigInt!"),
      ("big_uint", "BigInt!"),
      ("bytes_field", "String!"),
      ("fixed_bytes", "String!"),
      ("string_field", "String!"),
      ("uint_list", "[BigInt]!"),
      ("address_list", "[String]!"),
      ("tuple_member", "BigInt!"),
      ("nested_list", "Json!"),
      ("tuple_list", "Json!"),
    ])
  })

  // A list one branch leaves unset is a nullable list, not a list of nullable
  // elements — the elements it does hold always have a value.
  it("Types a list a branch selects null for as a nullable list", t => {
    let config = parse(`
name: nullable-list
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Batch(address[] recipients, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  rows:
    with:
      moves:
        - from: evm.events
          where:
            eventName: Batch
          select:
            key: params.value
            list: params.recipients
        - from: evm.events
          where:
            eventName: Transfer
          select:
            key: params.value
            list: null
    from: moves
    select:
      id: key
      recipients: list
`)
    t.expect(config->describeColumns("rows")).toEqual([
      ("id", "BigInt!"),
      ("recipients", "[String]"),
    ])
  })
})

// The ERC-20 template is the reference config: a `with` union feeding a `_sum`,
// a `_concat` id, references both ways and an inverse relationship.
describe("The ERC-20 template's inferred schema", () => {
  let config = parse(`
name: erc20
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  accounts:
    with:
      balance_changes:
        - from: evm.events
          where:
            eventName: Approval
          select:
            account: params.owner
            delta: 0
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.from
            delta:
              _negate: params.value
    from: balance_changes
    select:
      id: account
      balance:
        _sum: delta
      approvals:
        _derived_from: approvals.owner
  approvals:
    from: evm.events
    where:
      eventName: Approval
    select:
      id:
        _concat:
          separator: "-"
          values:
            - params.owner
            - params.spender
      amount: params.value
      owner:
        _ref:
          table: accounts
          id: params.owner
`)

  it("Widens a literal to the type its sibling branch produces", t =>
    // `delta: 0` in one branch and a uint256 in the other, so the column — and
    // the `_sum` over it — are BigInt rather than Int.
    t.expect(config->describeColumns("accounts")).toEqual([
      ("id", "String!"),
      ("balance", "BigInt!"),
      ("approvals", "derivedFrom approvals"),
    ])
  )

  it("Links a `_ref` column to its table, and keeps the inverse virtual", t =>
    t.expect(config->describeColumns("approvals")).toEqual([
      ("id", "String!"),
      ("amount", "BigInt!"),
      ("owner", "String -> accounts!"),
    ])
  )
})

// A table's `storage` says where it lands, overriding the config-wide default
// the same way an entity's `@storage` does.
describe("Per-table storage", () => {
  let config = parse(`
name: storage
disable_default_cross_chain: true
storage:
  postgres:
    default: true
  clickhouse:
    default: true
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
  both:
    from: evm.events
    select:
      id: params.to
  pg_only:
    storage:
      postgres:
        indexes:
          - received
          - [received, id]
    from: evm.events
    select:
      id: params.to
      received:
        _sum: params.value
  ch_only:
    storage:
      clickhouse:
        partition_by: "toYYYYMM(fromUnixTimestamp(0))"
        ttl: "now() + INTERVAL 1 DAY"
    from: evm.events
    select:
      id: params.to
`)

  let storageOf = table => {
    let {storage} = config.entitiesByTableName->Dict.getUnsafe(table)
    (storage.postgres, storage.clickhouse)
  }

  it("Routes each table to the backends it names", t =>
    t.expect((storageOf("both"), storageOf("pg_only"), storageOf("ch_only"))).toEqual((
      (true, true),
      (true, false),
      (false, true),
    ))
  )

  it("Declares the indexes the table asked for", t => {
    let {table} = config.entitiesByTableName->Dict.getUnsafe("pg_only")
    t.expect((
      table.fields->Array.filterMap(field =>
        switch field {
        | Table.Field({fieldName, isIndex: true}) => Some(fieldName)
        | _ => None
        }
      ),
      table.compositeIndexes->Array.map(index =>
        index->Array.map(({fieldName, direction}) =>
          `${fieldName} ${(direction :> string)}`
        )
      ),
    )).toEqual((["received"], [["received Asc", "id Asc"]]))
  })

  it("Keeps a ClickHouse expression intact", t => {
    let {storage} = config.entitiesByTableName->Dict.getUnsafe("ch_only")
    t.expect(
      storage.clickhouseOptions->(
        Utils.magic: option<Internal.clickhouseTableOptions> => JSON.t
      ),
    ).toEqual(
      {
        "partitionBy": "toYYYYMM(fromUnixTimestamp(0))",
        "ttl": "now() + INTERVAL 1 DAY",
      }->(Utils.magic: 'a => JSON.t),
    )
  })
})

// Selecting `transaction.hash` is what makes it get fetched, and the cost lands
// on the event that carries it — an event no table reads pays nothing.
describe("Fetching only the fields the tables select", () => {
  it("Adds demand to the event that selects it, and no other", t => {
    let config = parse(`
name: demand
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  transfers:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: transaction.hash
`)
    let contract = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let selectionOf = name =>
      switch (contract.contracts->Array.getUnsafe(0)).events->Array.find(e => e.name === name) {
      | Some(event) => event.fieldSelection.transactionFields->Utils.Set.toArray
      | None => ["the event is missing from the config"]
      }
    t.expect((selectionOf("Transfer"), selectionOf("Approval"))).toEqual((["hash"], []))
  })
})
