open Vitest

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

let configYaml = (~disableDefaultCrossChain) =>
  `
name: cross-chain
${disableDefaultCrossChain ? "disable_default_cross_chain: true" : ""}
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
`

let perChainConfig = InternalTestIndexer.fromUserApi(
  ~configYaml=configYaml(~disableDefaultCrossChain=true),
  ~schema,
).config

let entityConfig = (config: Config.t, name) =>
  config.userEntities->Array.find(e => e.name === name)->Option.getOrThrow

let counter = perChainConfig->entityConfig("Counter")
let globalCounter = perChainConfig->entityConfig("GlobalCounter")

describe("disable_default_cross_chain", () => {
  it("Resolves the default and each entity's own scope", t => {
    t.expect((
      perChainConfig.defaultCrossChain,
      counter.crossChain,
      globalCounter.crossChain,
    )).toEqual((false, false, true))
  })

  it("Leaves entities cross-chain without the flag", t => {
    let config = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(~disableDefaultCrossChain=false),
      ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
    ).config
    t.expect((config.defaultCrossChain, (config->entityConfig("Counter")).crossChain)).toEqual((
      true,
      true,
    ))
  })

  it("Appends a chain-id column only to per-chain entity tables", t => {
    t.expect((
      counter.table->Table.getChainIdField->Option.map(f => f.fieldName),
      globalCounter.table->Table.getChainIdField,
    )).toEqual((Some("chainId"), None))
  })
})

// Codegen errors, asserted through the same parse path a user hits.
let parseError = (~schema, ~disableDefaultCrossChain=true) =>
  try {
    let _ = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(~disableDefaultCrossChain),
      ~schema,
    )
    None
  } catch {
  | exn =>
    Some(exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string})->(e => e["message"]))
  }

describe("Cross-chain schema validation", () => {
  it("Rejects @crossChain when entities are already cross-chain by default", t => {
    t.expect(parseError(~schema, ~disableDefaultCrossChain=false)).toEqual(
      Some(
        "@crossChain on `GlobalCounter` has no effect because entities are cross-chain by default. Set `disable_default_cross_chain: true` in config.yaml to make entities per-chain, or remove the directive.",
      ),
    )
  })

  it("Reserves the chain-id names on per-chain entities only", t => {
    let withChainIdField = `
type Counter {
  id: ID!
  chainId: Int!
}
`
    t.expect((
      parseError(~schema=withChainIdField),
      parseError(~schema=withChainIdField, ~disableDefaultCrossChain=false),
      parseError(
        ~schema=`
type Counter @crossChain {
  id: ID!
  chainId: Int!
}
`,
      ),
    )).toEqual((
      Some(
        "`Counter.chainId` is not allowed, since envio sets `chainId` on every per-chain entity for you. Either rename the field, or add `@crossChain` to `Counter` — its rows are then shared across chains and the field is yours to set.",
      ),
      // Cross-chain entities have nothing appended, so the name is free.
      None,
      None,
    ))
  })

  // Which spelling the column takes depends on the backend's
  // `column_name_format`, but a name a user may give a field shouldn't: both
  // are reserved wherever the entity is stored.
  it("Reserves both spellings regardless of the storage backends", t => {
    let reserved = (~name, ~storage) =>
      try {
        let _ = InternalTestIndexer.fromUserApi(
          ~configYaml=configYaml(~disableDefaultCrossChain=true) ++ storage,
          ~schema=`
type Counter {
  id: ID!
  ${name}: Int!
}
`,
        )
        false
      } catch {
      | _ => true
      }

    let postgresOnly = ""
    let snakeCaseClickHouse = `storage:
  postgres:
    column_name_format: original
  clickhouse:
    column_name_format: snake_case
`
    t.expect((
      reserved(~name="chainId", ~storage=postgresOnly),
      reserved(~name="chain_id", ~storage=postgresOnly),
      reserved(~name="chainId", ~storage=snakeCaseClickHouse),
      reserved(~name="chain_id", ~storage=snakeCaseClickHouse),
    )).toEqual((true, true, true, true))
  })

  // A derived field has no column of its own, so a check that only looked at
  // physical columns let it through — and the appended chain id then collided
  // with it on the entity's GraphQL surface.
  it("Rejects a @derivedFrom field that claims the chain-id name", t => {
    t.expect(
      parseError(
        ~schema=`
type Counter {
  id: ID!
  chainId: [Tally!]! @derivedFrom(field: "counter")
}
type Tally {
  id: ID!
  counter: Counter!
}
`,
      )->Option.map(m => m->String.includes("`Counter.chainId`")),
    ).toEqual(Some(true))
  })

  it("Rejects a cross-chain entity referencing a per-chain one", t => {
    t.expect(
      parseError(
        ~schema=`
type Counter {
  id: ID!
}
type GlobalCounter @crossChain {
  id: ID!
  counter: Counter!
}
`,
      ),
    ).toEqual(
      Some(`Schema validation failed:

Cross-chain entities referencing per-chain entities:
  - \`GlobalCounter\`.\`counter\` references \`Counter\`, which is per-chain.

A reference stores only the referenced entity's id, and a per-chain id needs a chain to resolve. Fixes:
  - Make the referenced entities cross-chain with \`@crossChain\`, or
  - Remove \`@crossChain\` from the entities listed above so they resolve the reference within their own chain.`),
    )
  })

  it("Allows every other combination of reference scopes", t => {
    t.expect((
      // per-chain -> per-chain: resolved within the referencing entity's chain.
      parseError(
        ~schema=`
type Counter { id: ID! }
type Tally { id: ID! counter: Counter! }
`,
      ),
      // per-chain -> cross-chain: a cross-chain id is global.
      parseError(
        ~schema=`
type Counter @crossChain { id: ID! }
type Tally { id: ID! counter: Counter! }
`,
      ),
      // cross-chain -> cross-chain.
      parseError(
        ~schema=`
type Counter @crossChain { id: ID! }
type Tally @crossChain { id: ID! counter: Counter! }
`,
      ),
      // Nothing is per-chain at all.
      parseError(
        ~schema=`
type Counter { id: ID! }
type Tally { id: ID! counter: Counter! }
`,
        ~disableDefaultCrossChain=false,
      ),
    )).toEqual((None, None, None, None))
  })

  it("Rejects a @derivedFrom whose forward reference crosses scopes", t => {
    t.expect(
      parseError(
        ~schema=`
type Counter {
  id: ID!
  tallies: [Tally!]! @derivedFrom(field: "counter")
}
type Tally @crossChain {
  id: ID!
  counter: Counter!
}
`,
      )->Option.map(m => m->String.includes("`Tally`.`counter` references `Counter`")),
    ).toEqual(Some(true))
  })
})

// The sequence decides the checkpoints table's key: ids are only unique within
// a chain where each chain counts its own, and under one shared sequence every
// bound a rollback or a prune applies is an id range.
describe("Checkpoint sequence", () => {
  let sequenceOf = (~schema) =>
    InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(~disableDefaultCrossChain=true),
      ~schema,
    ).config.checkpointSequence

  it("Counts each chain on its own when every entity is per-chain", t => {
    t.expect(
      sequenceOf(
        ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
      ),
    ).toBe(PerChain)
  })

  it("Shares one count once a cross-chain entity is in the schema", t => {
    t.expect(
      sequenceOf(
        ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
type Total @crossChain {
  id: ID!
  count: BigInt!
}
`,
      ),
    ).toBe(SharedAcrossChains)
  })
})

// The appended column is spelled by the backend's `column_name_format`, while
// the entity object and the getWhere filter keep using `chainId`. The two names
// are used in different places, so pin both.
describe("Per-chain entities under snake_case columns", () => {
  let snakeConfig = InternalTestIndexer.fromUserApi(
    ~configYaml=configYaml(~disableDefaultCrossChain=true) ++ `storage:
  postgres:
    column_name_format: snake_case
`,
    ~schema,
  ).config
  let snakeCounter = snakeConfig->entityConfig("Counter")

  it("Keeps the API field name but writes the snake_case column", t => {
    let field = snakeCounter.table->Table.getChainIdField->Option.getOrThrow
    t.expect((field.fieldName, field->Table.getPgDbFieldName)).toEqual(("chainId", "chain_id"))
  })

  it("Names the column the addon partitions and keys history by", t => {
    t.expect(snakeCounter.table->Table.getPgChainIdColumn).toEqual(Some("chain_id"))
  })

  it("Keys the getWhere filter by the API name", t => {
    t.expect(
      snakeCounter.table
      ->Table.queryFields
      ->Dict.get("chainId")
      ->Option.map(f => f.pgDbFieldName),
    ).toEqual(Some("chain_id"))
  })
})

// A relationship between two per-chain entities is only meaningful within one
// chain. Hasura joins on the column_mapping alone, so the chain has to be in it.
describe("Per-chain Hasura relationships", () => {
  it("Joins on the chain id when both sides are per-chain", t => {
    t.expect((
      Hasura.makeColumnMapping(
        ~relationalKey="counter_id",
        ~isDerivedFrom=false,
        ~chainIdColumn=Some("chainId"),
      ),
      Hasura.makeColumnMapping(
        ~relationalKey="counter_id",
        ~isDerivedFrom=true,
        ~chainIdColumn=Some("chainId"),
      ),
    )).toEqual((
      `{"counter_id": "id", "chainId": "chainId"}`,
      `{"id": "counter_id", "chainId": "chainId"}`,
    ))
  })

  it("Joins on the id alone when either side is cross-chain", t => {
    t.expect((
      Hasura.makeColumnMapping(
        ~relationalKey="counter_id",
        ~isDerivedFrom=false,
        ~chainIdColumn=None,
      ),
      Hasura.makeColumnMapping(
        ~relationalKey="counter_id",
        ~isDerivedFrom=true,
        ~chainIdColumn=None,
      ),
    )).toEqual((`{"counter_id": "id"}`, `{"id": "counter_id"}`))
  })
})

describe("Chain-id stamping", () => {
  let entity =
    {"id": "total", "count": 5n}->(Utils.magic: {"id": string, "count": bigint} => Internal.entity)

  it("Copies the entity rather than mutating the handler's object", t => {
    let stamped = entity->Internal.stampChainId(~fieldName="chainId", ~chainId=137->ChainId.fromInt)
    t.expect((
      stamped->(Utils.magic: Internal.entity => {"id": string, "count": bigint, "chainId": int}),
      entity->(Utils.magic: Internal.entity => {..})->Obj.magic->Dict.keysToArray,
    )).toEqual(({"id": "total", "count": 5n, "chainId": 137}, ["id", "count"]))
  })
})

describe("Effect scope defaults", () => {
  let makeEffect = (~crossChain=?) =>
    Envio.createEffect(
      {
        name: "probe",
        input: S.string,
        output: S.string,
        rateLimit: Disable,
        ?crossChain,
      },
      async ({input}) => input,
    )->(Utils.magic: Envio.effect<string, string> => Internal.effect)

  it("Leaves an unset scope for the config to resolve", t => {
    t.expect((
      makeEffect().crossChain,
      makeEffect(~crossChain=true).crossChain,
      makeEffect(~crossChain=false).crossChain,
    )).toEqual((None, Some(true), Some(false)))
  })

  it("Resolves an unset scope against the config default", t => {
    let resolve = (effect: Internal.effect, ~defaultCrossChain) =>
      effect.crossChain->Option.getOr(defaultCrossChain)
    t.expect((
      makeEffect()->resolve(~defaultCrossChain=false),
      makeEffect()->resolve(~defaultCrossChain=true),
      makeEffect(~crossChain=true)->resolve(~defaultCrossChain=false),
    )).toEqual((false, true, true))
  })
})

// `envio_info` is diffed path by path against the JSON stored on the last
// successful init, so a field that only ever repeats a default would force
// every project predating it to reset and reindex.
describe("Public config compatibility", () => {
  let publicJson = (~schema, ~disableDefaultCrossChain) =>
    Core.fromUserApi(~schema, configYaml(~disableDefaultCrossChain)).config->JSON.parseOrThrow

  let key = (json: JSON.t, k) =>
    switch json {
    | Object(d) => d->Dict.get(k)
    | _ => None
    }

  let entityKey = (json, name, k) =>
    json
    ->key("entities")
    ->Option.flatMap(entities =>
      switch entities {
      | Array(arr) => arr->Array.find(e => e->key("name") === Some(JSON.Encode.string(name)))
      | _ => None
      }
    )
    ->Option.flatMap(e => e->key(k))

  it("Omits the scope fields a default project would only repeat", t => {
    let json = publicJson(
      ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
      ~disableDefaultCrossChain=false,
    )
    t.expect((json->key("defaultCrossChain"), json->entityKey("Counter", "crossChain"))).toEqual((
      None,
      None,
    ))
  })

  it("Emits only the scopes that differ from the resolved default", t => {
    let json = publicJson(~schema, ~disableDefaultCrossChain=true)
    t.expect((
      json->key("defaultCrossChain"),
      json->entityKey("Counter", "crossChain"),
      json->entityKey("GlobalCounter", "crossChain"),
    )).toEqual((Some(JSON.Encode.bool(false)), None, Some(JSON.Encode.bool(true))))
  })
})
