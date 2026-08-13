open Vitest

// Every way a `tables:` config can be wrong, and the message it gets. These are
// the errors a user meets while writing config.yaml, so each one is asserted in
// full: a message that names the wrong key and what to write instead is the
// whole feature here.
let table = body => `
name: materialized-validation
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
${body}`

let expectError = (t, ~schema=?, yaml, message) => {
  let actual = try {
    InternalTestIndexer.fromUserApi(~schema?, ~configYaml=yaml)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }
  t.expect(actual).toBe(message)
}

let prefix = "Config parse error: Failed compiling `tables`: in `tables.totals`: "

describe("tables: source and shape", () => {
  [
    (
      "rejects a `from` that is neither a source nor a `with` query",
      `  totals:
    from: evm.logs
    select:
      id: params.to`,
      prefix ++
      "`from: evm.logs` is not a source. Use `evm.events`, or the name of one of this table's `with` queries.",
    ),
    (
      "rejects a table with no `id`",
      `  totals:
    from: evm.events
    select:
      total:
        _sum: params.value`,
      prefix ++ "every table must select an `id`",
    ),
    (
      "rejects a `where` that matches no configured event",
      `  totals:
    from: evm.events
    where:
      eventName: Mint
    select:
      id: params.to`,
      prefix ++
      "in `where`: `eventName: Mint` is not configured on any contract. Configured events: Approval, Transfer",
    ),
    (
      "rejects a `where` on a contract that isn't configured",
      `  totals:
    from: evm.events
    where:
      contractName: ERC721
    select:
      id: params.to`,
      prefix ++
      "in `where`: `contractName: ERC721` is not configured. Configured contracts: ERC20",
    ),
    (
      "rejects a `where` on a table reading a `with` query",
      `  totals:
    with:
      moves:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.to
    from: moves
    where:
      chainId: 1
    select:
      id: account`,
      prefix ++
      "a table reading a `with` query can't have its own `where`. Move the conditions into the `with` queries.",
    ),
    (
      "rejects a `with` query nothing reads",
      `  totals:
    with:
      moves:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.to
    from: evm.events
    select:
      id: params.to`,
      prefix ++
      "`with` declares moves, but `from: evm.events` reads none of them. Set `from` to one of them, or drop `with`.",
    ),
    (
      "rejects `with` queries that select different columns",
      `  totals:
    with:
      moves:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.to
        - from: evm.events
          where:
            eventName: Approval
          select:
            holder: params.owner
    from: moves
    select:
      id: account`,
      prefix ++
      "every query in `with.moves` must select the same columns, but got [account] and [holder]",
    ),
    (
      "rejects a table that is also an entity in schema.graphql",
      `  totals:
    from: evm.events
    select:
      id: params.to`,
      "Config parse error: Failed compiling `tables`: `totals` is defined twice: in `tables` and in schema.graphql. Remove one of them.",
    ),
  ]->Array.forEach(((name, body, message)) => {
    it(name, t => {
      let schema = name->String.includes("schema.graphql")
        ? Some(`
type totals {
  id: ID!
}
`)
        : None
      expectError(t, ~schema?, body->table, message)
    })
  })
})

describe("tables: the id column", () => {
  [
    (
      "rejects a `_sum` id",
      `      id:
        _sum: params.value`,
      "`select.id` can't be a `_sum`: the id names the row, it isn't added up",
    ),
    (
      "rejects an id that can be null",
      `      id: block.mixHash`,
      "`select.id` must always be set and hold a single value, but it is String or null",
    ),
    (
      "rejects an id that isn't a string or number",
      `      id: true`,
      "`select.id` is Boolean, which can't be an id. Use String, Int or BigInt.",
    ),
  ]->Array.forEach(((name, select, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
${select}`->table,
          prefix ++ message,
        ),
    )
  })
})

// A `select` value is an event field, a literal, or an object naming one
// operator. Everything else is a mistake with a message that lists what fits.
describe("tables: select expressions", () => {
  [
    (
      "rejects a path that isn't a field of the event",
      `      id: params.owenr`,
      "in `select.id`: `ERC20.Transfer` has no parameter `owenr`. Available: from, to, value",
    ),
    (
      "rejects a path that goes too deep",
      `      id: params.to.owner`,
      "in `select.id`: `params.to` has no field `owner`",
    ),
    (
      "rejects a top-level field that doesn't exist",
      `      id: blocke.number`,
      "in `select.id`: `blocke` is not a field of `evm.events`. Available: contractName, eventName, chainId, srcAddress, logIndex, params, block, transaction. To write the text `blocke` instead, use `_literal: blocke`.",
    ),
    (
      "rejects selecting a whole record",
      `      id: params`,
      "in `select.id`: `params` has several fields — pick one, e.g. `params.from`",
    ),
    (
      "rejects a string constant written as a path",
      `      id: params.to
      kind: large`,
      "in `select.kind`: `large` is not a field of `evm.events`. Available: contractName, eventName, chainId, srcAddress, logIndex, params, block, transaction. To write the text `large` instead, use `_literal: large`.",
    ),
    (
      "rejects a list",
      `      id:
        - params.to`,
      "in `select.id`: a list is not a value. Use `_concat` to join several values into one.",
    ),
    (
      "rejects an object with no operator",
      `      id:
        value: params.to`,
      "in `select.id`: an object needs one of `_value`, `_literal`, `_negate`, `_sum`, `_concat`, `_ref`, `_derived_from` to say what the value is.",
    ),
    (
      "rejects two operators in one object",
      `      id: params.to
      total:
        _sum: params.value
        _negate: params.value`,
      "in `select.total`: expected exactly one of `_value`, `_literal`, `_negate`, `_sum`, `_concat`, `_ref`, `_derived_from`, plus an optional `_description`, but got: _sum, _negate",
    ),
    (
      "rejects an unknown operator",
      `      id:
        _upper: params.to`,
      "in `select.id`: `_upper` is not one of `_value`, `_literal`, `_negate`, `_sum`, `_concat`, `_ref`, `_derived_from`",
    ),
    (
      "rejects a `_sum` of something that isn't a number",
      `      id: params.to
      total:
        _sum: params.from`,
      "in `select.total`: `_sum` needs a number, but got String",
    ),
    (
      "rejects a `_negate` of something that isn't a number",
      `      id: params.to
      total:
        _negate: params.from`,
      "in `select.total`: `_negate` needs a number, but got String",
    ),
    (
      "rejects an integer too big for an Int column",
      `      id: params.to
      total: 5000000000`,
      "in `select.total`: 5000000000 is too big for an Int column. Select a BigInt value (a uint256 param, say) into the same column so the column becomes BigInt.",
    ),
    (
      "rejects a column that is only ever null",
      `      id: params.to
      total: null`,
      "in `select.total`: this is always null, so its type is unknown. Select a value that has a type, or drop the field.",
    ),
    (
      "rejects `_sum` nested inside another expression",
      `      id: params.to
      total:
        _negate:
          _sum: params.value`,
      "in `select.total`: in `_negate`: `_sum` can only be used directly on a `select` field",
    ),
  ]->Array.forEach(((name, select, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
${select}`->table,
          prefix ++ message,
        ),
    )
  })
})

describe("tables: _concat", () => {
  [
    (
      "rejects an unknown option",
      `        _concat:
          seperator: "-"
          values:
            - params.to`,
      "`_concat` has no `seperator` option. It takes `values` and `separator`.",
    ),
    (
      "rejects an empty list of values",
      `        _concat: []`,
      "`_concat.values` must not be empty",
    ),
    (
      "rejects a value that can't be joined as text",
      `        _concat:
            - params.to
            - block.mixHash`,
      "`_concat.values[1]` is String or null, and a null would make two different rows join to the same text. Select a value that is always set.",
    ),
  ]->Array.forEach(((name, value, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id:
${value}`->table,
          prefix ++ "in `select.id`: " ++ message,
        ),
    )
  })
})

describe("tables: _ref and _derived_from", () => {
  [
    (
      "rejects a `_ref` at a table that isn't declared",
      `      owner:
        _ref:
          table: holders
          id: params.to`,
      "in `select.owner`: `_ref.table` is `holders`, which is not one of the tables in `tables`",
    ),
    (
      "rejects a `_ref` with an unknown option",
      `      owner:
        _ref:
          table: totals
          id: params.to
          on: params.from`,
      "in `select.owner`: `_ref` has no `on` option. It takes `table` and `id`.",
    ),
    (
      "rejects a `_derived_from` that isn't `<table>.<field>`",
      `      incoming:
        _derived_from: totals`,
      "in `select.incoming`: `_derived_from` takes `<table>.<field>`, e.g. `approvals.owner`, but got `totals`",
    ),
    (
      "rejects a `_derived_from` at a table that isn't declared",
      `      incoming:
        _derived_from: holders.owner`,
      "in `select.incoming`: `_derived_from` names table `holders`, which is not one of the tables in `tables`",
    ),
  ]->Array.forEach(((name, extra, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
${extra}`->table,
          prefix ++ message,
        ),
    )
  })
})

describe("tables: _description", () => {
  [
    (
      "rejects a description with no value to describe",
      `      total:
        _description: "How much"`,
      "in `select.total`: `_description` needs a value beside it, such as `_value: params.owner` or `_sum: params.value`.",
    ),
    (
      "rejects a description on a nested expression",
      `      total:
        _negate:
          _value: params.value
          _description: "How much"`,
      "in `select.total`: in `_negate`: `_description` describes a column, so it only works on a table's own `select` field",
    ),
  ]->Array.forEach(((name, extra, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
${extra}`->table,
          prefix ++ message,
        ),
    )
  })

  it("rejects a description on a `with` query's column", t =>
    expectError(
      t,
      `  totals:
    with:
      moves:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.to
            delta:
              _value: params.value
              _description: "How much"
    from: moves
    select:
      id: account`->table,
      prefix ++ "in `with.moves[0].select.delta`: `_description` describes a column, so it only works on a table's own `select` field",
    )
  )
})

describe("tables: where conditions", () => {
  [
    (
      "rejects an unknown comparison",
      `      params:
        value:
          _between: 5`,
      "`_between` is not a known filter operator. Available: _eq, _neq, _gt, _gte, _lt, _lte, _in, _nin",
    ),
    (
      "rejects a comparison at the top of `where`",
      `      _gte: 5`,
      "`_gte` compares one field, so it goes under a field name, not at the top of `where`",
    ),
    (
      "rejects an empty condition object",
      `      params:
        value: {}`,
      "`params.value` has nothing to compare it to. Add a condition such as `_eq`.",
    ),
    (
      "rejects an empty `_and`",
      `      _and: []`,
      "`_and` must not be empty",
    ),
    (
      "rejects an ordering comparison on a name",
      `      eventName:
        _gt: Transfer`,
      "`eventName` only supports `_eq`/`_neq`/`_in`",
    ),
  ]->Array.forEach(((name, condition, message)) => {
    it(
      name,
      t =>
        expectError(
          t,
          `  totals:
    from: evm.events
    where:
${condition}
    select:
      id: params.to`->table,
          prefix ++ "in `where`: " ++ message,
        ),
    )
  })
})

describe("tables: names and storage", () => {
  [
    (
      "rejects a table name that isn't an identifier",
      `  totals-2:
    from: evm.events
    select:
      id: params.to`,
      "Config parse error: Table name `totals-2` is not a valid identifier. Use letters, digits and underscores, starting with a letter or an underscore.",
    ),
    (
      "rejects a table name that leaves nothing to call it",
      `  _1:
    from: evm.events
    select:
      id: params.to`,
      "Config parse error: Table name `_1` leaves the generated code nothing to call it: handlers and tests reach a table by its name capitalized and stripped of leading underscores. Start it with a letter.",
    ),
    (
      "rejects two table names the generated code can't tell apart",
      `  totals:
    from: evm.events
    select:
      id: params.to
  _Totals:
    from: evm.events
    select:
      id: params.to`,
      "Config parse error: tables `totals` and `_Totals` are both `Totals` in the generated code, which can't tell them apart. Rename one of them.",
    ),
    (
      "rejects an `as_entity` name handlers can't use",
      `  totals:
    as_entity: totals
    from: evm.events
    select:
      id: params.to`,
      "Config parse error: Failed compiling `tables`: `tables.totals.as_entity` is `totals`, which handlers can't use as a name. Use letters, digits and underscores, starting with a capital.",
    ),
    (
      "rejects an index on a field the table doesn't select",
      `  totals:
    storage:
      postgres:
        indexes:
          - received
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to`,
      prefix ++
      "`storage.postgres.indexes` names `received`, which this table doesn't select. Available: id",
    ),
    (
      "rejects a backend config.yaml never enabled",
      `  totals:
    storage:
      clickhouse: true
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to`,
      "Config parse error: Schema validation failed:\n\nEntities using storages not enabled in config.yaml:\n  - `totals` uses `clickhouse`, but `clickhouse` is not enabled.\n\nFixes:\n  - Remove the unsupported storage from @storage on these entities, or enable it under `storage:` in config.yaml.",
    ),
  ]->Array.forEach(((name, body, message)) => {
    it(name, t => expectError(t, body->table, message))
  })
})

// Naming one backend turns the other off. With nothing marked `default: true`
// there is no stated intent to fall back on, so the omission has to be spelled
// out — otherwise asking for a Postgres index quietly stops the table reaching
// ClickHouse.
describe("tables: naming one backend when both are enabled", () => {
  let bothEnabled = (~defaults="", tableStorage) => `
name: partial-storage
disable_default_cross_chain: true
storage:
  postgres:${defaults === "postgres" ? "\n    default: true" : " true"}
  clickhouse: true
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
  totals:
${tableStorage}    from: evm.events
    select:
      id: params.to
      received:
        _sum: params.value
`

  let partialMessage = says =>
    "Config parse error: Schema validation failed:\n\nBoth storage backends are enabled and neither is `default: true`, so leaving one out of a table's storage would turn it off silently:\n  - `totals` says " ++
    says ++
    "\n\nFixes:\n  - Name both, under the table's `storage:` in config.yaml:\n      storage:\n        postgres: true\n        clickhouse: false\n  - Or set `default: true` on one backend under `storage:` in config.yaml, and leave the storage off the tables that should follow it."

  it("rejects a table that asks for an index and says nothing about clickhouse", t =>
    expectError(
      t,
      bothEnabled(`    storage:
      postgres:
        indexes:
          - received
`),
      partialMessage("postgres, not clickhouse"),
    )
  )

  it("rejects a table that names clickhouse only", t =>
    expectError(
      t,
      bothEnabled(`    storage:
      clickhouse: true
`),
      partialMessage("clickhouse, not postgres"),
    )
  )

  it("accepts a table that names both", t =>
    expectError(
      t,
      bothEnabled(`    storage:
      postgres:
        indexes:
          - received
      clickhouse: false
`),
      "the parse to fail, but it succeeded",
    )
  )

  // The rule arrived with `tables`, so a schema that predates it keeps working.
  it("leaves a config without tables alone", t =>
    expectError(
      t,
      ~schema=`
type Note @storage(postgres: true) {
  id: ID!
}
`,
      `
name: partial-storage-no-tables
storage:
  postgres: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
`,
      "the parse to fail, but it succeeded",
    )
  )

  // A stated default is the intent to fall back on, so a table overriding it is
  // a deliberate act rather than an omission.
  it("accepts naming one backend once a default is stated", t =>
    expectError(
      t,
      bothEnabled(
        ~defaults="postgres",
        `    storage:
      clickhouse: true
`,
      ),
      "the parse to fail, but it succeeded",
    )
  )
})

// `tables` is an EVM key. Serde's unknown-field check doesn't reach through the
// ecosystem flattening, so this is the one that would silently do nothing.
describe("tables: other ecosystems", () => {
  it("rejects tables on a Fuel config", t =>
    expectError(
      t,
      `
name: fuel-tables
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
tables:
  rows:
    from: evm.events
    select:
      id: params.x
`,
      "Config parse error: Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: unknown field `tables` at line 2 column 1",
    )
  )
})

// Without per-chain rows every table shares one row per id across all chains,
// which for a token indexer silently merges two chains' balances.
describe("tables: cross-chain default", () => {
  it("requires disable_default_cross_chain", t =>
    expectError(
      t,
      `
name: materialized-validation
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
  totals:
    from: evm.events
    select:
      id: params.to
`,
      "Config parse error: `tables` needs `disable_default_cross_chain: true` at the top of config.yaml. Without it a table keeps one row per id shared by every chain, so the same id on two chains overwrites itself — for a token indexer that silently merges balances. Add:\n\n    disable_default_cross_chain: true\n\nand set `cross_chain: true` on any table that really is the same across chains.",
    )
  )
})

// Handlers, generated modules and the test indexer all address a table by one
// code name, so two tables that land on the same one are indistinguishable
// there however different their database tables are.
describe("tables: code-name collisions", () => {
  it("rejects a table whose name collides with a schema.graphql entity", t =>
    expectError(
      t,
      ~schema="type Totals { id: ID! }",
      `  totals:
    from: evm.events
    select:
      id: params.to`->table,
      "Config parse error: Failed compiling `tables`: `totals` and `Totals` in schema.graphql are both `Totals` in the generated code, which can't tell them apart. Rename one of them, or give one a different `as_entity`.",
    )
  )

  it("rejects an `as_entity` that collides with a schema.graphql entity", t =>
    expectError(
      t,
      ~schema="type Receipt { id: ID! }",
      `  totals:
    as_entity: Receipt
    from: evm.events
    select:
      id: params.to`->table,
      "Config parse error: Failed compiling `tables`: `tables.totals.as_entity` and `Receipt` in schema.graphql are both `Receipt` in the generated code, which can't tell them apart. Rename one of them, or give one a different `as_entity`.",
    )
  )

  it("rejects two tables that pick the same `as_entity`", t =>
    expectError(
      t,
      `  totals:
    as_entity: Receipt
    from: evm.events
    select:
      id: params.to
  other_totals:
    as_entity: Receipt
    from: evm.events
    select:
      id: params.to`->table,
      "Config parse error: Failed compiling `tables`: `tables.other_totals.as_entity` and `tables.totals.as_entity` are both `Receipt` in the generated code, which can't tell them apart. Rename one of them, or give one a different `as_entity`.",
    )
  )

  // The whole point of `as_entity`: a table whose name would collide keeps its
  // own database name and answers to a different one in code.
  it("accepts a collision that `as_entity` resolves", t => {
    let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
      ~schema="type Totals { id: ID! }",
      ~configYaml=`  totals:
    as_entity: Receipt
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to`->table,
    )
    t.expect(
      config.userEntities->Array.map((e: Internal.entityConfig) => (e.name, e.codeName)),
    ).toEqual([("Totals", "Totals"), ("totals", "Receipt")])
  })
})

// A `_ref` writes the target's id into the referencing column, so it has to
// hold the type that column will have — which is whatever the target's own
// `select.id` settled on, not always a String.
describe("tables: _ref id types", () => {
  let refTo = (targetId, refId) =>
    `  targets:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: ${targetId}
  holders:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      target:
        _ref:
          table: targets
          id: ${refId}`->table

  it("rejects a reference whose id doesn't match the table it points at", t =>
    expectError(
      t,
      refTo("logIndex", "params.to"),
      "Config parse error: Failed compiling `tables`: in `tables.holders`: in `select.target._ref.id`: `targets` has Int for an id: expected Int but the expression is String: cannot unify String with Int",
    )
  )

  [("logIndex", "Int"), ("params.value", "BigInt"), ("params.to", "String")]->Array.forEach(((
    id,
    described,
  )) =>
    it(
      `Accepts a reference to ${described} ids`,
      t => {
        let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
          ~configYaml=refTo(id, id),
        )
        t.expect(
          config.userEntities
          ->Array.filter((e: Internal.entityConfig) => e.name === "targets")
          ->Array.map((e: Internal.entityConfig) => e.table.fields->Array.length),
        ).toEqual([2])
      },
    )
  )
})
