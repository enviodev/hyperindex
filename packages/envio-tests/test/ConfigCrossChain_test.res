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

let configYaml = (~disableDefaultCrossChain) => `
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

let perChainConfig =
  InternalTestIndexer.fromUserApi(~configYaml=configYaml(~disableDefaultCrossChain=true), ~schema).config

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
    let config =
      InternalTestIndexer.fromUserApi(
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
  | exn => Some(exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string})->(e => e["message"]))
  }

describe("Cross-chain schema validation", () => {
  it("Rejects @crossChain when entities are already cross-chain by default", t => {
    t.expect(parseError(~schema, ~disableDefaultCrossChain=false)).toEqual(
      Some(
        "Config parse error: @crossChain on `GlobalCounter` has no effect because entities are cross-chain by default. Set `disable_default_cross_chain: true` in config.yaml to make entities per-chain, or remove the directive.",
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
        "Config parse error: `Counter.chainId` is not allowed, since envio sets `chainId` on every per-chain entity for you. Either rename the field, or add `@crossChain` to `Counter` — its rows are then shared across chains and the field is yours to set.",
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
      Some(
        `Config parse error: Schema validation failed:

Cross-chain entities referencing per-chain entities:
  - \`GlobalCounter\`.\`counter\` references \`Counter\`, which is per-chain.

A reference stores only the referenced entity's id, and a per-chain id needs a chain to resolve. Fixes:
  - Make the referenced entities cross-chain with \`@crossChain\`, or
  - Remove \`@crossChain\` from the entities listed above so they resolve the reference within their own chain.`,
      ),
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

describe("Per-chain entity DDL", () => {
  it("Puts the chain id in the entity table's primary key", t => {
    t.expect(
      PgStorage.makeCreateTableQuery(
        counter.table,
        ~pgSchema="public",
        ~isNumericArrayAsText=false,
      ),
    ).toBe(
      `CREATE TABLE IF NOT EXISTS "public"."Counter"("id" TEXT NOT NULL, "count" NUMERIC NOT NULL, "chainId" INTEGER NOT NULL, PRIMARY KEY("id", "chainId"));`,
    )
  })

  it("Keeps a cross-chain entity's primary key on the id alone", t => {
    t.expect(
      PgStorage.makeCreateTableQuery(
        globalCounter.table,
        ~pgSchema="public",
        ~isNumericArrayAsText=false,
      ),
    ).toBe(
      `CREATE TABLE IF NOT EXISTS "public"."GlobalCounter"("id" TEXT NOT NULL, "count" NUMERIC NOT NULL, PRIMARY KEY("id"));`,
    )
  })

  it("Carries the chain id into the history table's primary key, not nullable", t => {
    let historyTable = PgStorage.getEntityHistory(~entityConfig=counter).table
    t.expect(historyTable->Table.getPgPrimaryKeyFieldNames).toEqual([
      "id",
      "chainId",
      "envio_checkpoint_id",
    ])
  })
})

describe("Per-chain rollback and delete SQL", () => {
  it("Keys the removed-ids query on (id, chain id)", t => {
    t.expect(
      PgStorage.makeGetRollbackRemovedIdsQuery(~entityConfig=counter, ~pgSchema="public"),
    ).toBe(
      `SELECT DISTINCT "id", "chainId"
  FROM "public"."envio_history_Counter"
  WHERE "envio_checkpoint_id" > $1
    AND NOT EXISTS (
      SELECT 1
      FROM "public"."envio_history_Counter" h
      WHERE h."id" = "envio_history_Counter"."id" AND h."chainId" = "envio_history_Counter"."chainId"
        AND h."envio_checkpoint_id" <= $1
    )`,
    )
  })

  it("Dedups the pre-target restore per (id, chain id)", t => {
    let query = PgStorage.makeGetRollbackPreTargetRowsQuery(~entityConfig=counter, ~pgSchema="public")
    t.expect((
      query->String.includes(`SELECT DISTINCT ON ("id", "chainId")`),
      query->String.includes(`ORDER BY "id", "chainId", "envio_checkpoint_id" DESC`),
    )).toEqual((true, true))
  })

  it("Narrows a delete to the flush group's chain", t => {
    t.expect(
      PgStorage.makeDeleteByIdQuery(
        ~pgSchema="public",
        ~tableName="Counter",
        ~chainIdCondition=PgStorage.makeChainIdCondition(
          ~table=counter.table,
          ~chainId=Some(137->ChainId.fromInt),
        ),
      ),
    ).toBe(`DELETE FROM "public"."Counter" WHERE id = $1 AND "chainId" = $2;`)
  })

  it("Leaves a cross-chain entity's delete unfiltered", t => {
    t.expect(
      PgStorage.makeChainIdCondition(~table=globalCounter.table, ~chainId=Some(137->ChainId.fromInt)),
    ).toBe("")
  })

  it("Prunes history per (id, chain id)", t => {
    let query = EntityHistory.makePruneStaleEntityHistoryQuery(
      ~entityName="Counter",
      ~entityIndex=0,
      ~pgSchema="public",
      ~chainIdColumn=Some("chainId"),
    )
    t.expect((
      query->String.includes(`GROUP BY t.id, t."chainId"`),
      query->String.includes(`WHERE d.id = a.id AND d."chainId" = a."chainId"`),
    )).toEqual((true, true))
  })

  it("Pins the backfill to the flush group's chain", t => {
    t.expect(
      EntityHistory.makeBackfillHistoryQuery(
        ~pgSchema="public",
        ~entityName="Counter",
        ~entityIndex=0,
        ~idPgType="TEXT",
        ~chainIdColumn=Some("chainId"),
        ~chainId=Some(1->ChainId.fromInt),
      )->String.includes(`JOIN target_ids t ON e.id = t.id AND e."chainId" = $2`),
    ).toBe(true)
  })
})

// The appended column is spelled by the backend's `column_name_format`, while
// the entity object and the getWhere filter keep using `chainId`. The two names
// are used in different places, so pin both.
describe("Per-chain entities under snake_case columns", () => {
  let snakeConfig =
    InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(~disableDefaultCrossChain=true) ++
      `storage:
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

  it("Uses the column name in the DDL and the row-level predicates", t => {
    t.expect((
      PgStorage.makeCreateTableQuery(
        snakeCounter.table,
        ~pgSchema="public",
        ~isNumericArrayAsText=false,
      ),
      PgStorage.makeChainIdCondition(
        ~table=snakeCounter.table,
        ~chainId=Some(137->ChainId.fromInt),
      ),
      PgStorage.makeGetRollbackRemovedIdsQuery(
        ~entityConfig=snakeCounter,
        ~pgSchema="public",
      )->String.includes(`SELECT DISTINCT "id", "chain_id"`),
    )).toEqual((
      `CREATE TABLE IF NOT EXISTS "public"."Counter"("id" TEXT NOT NULL, "count" NUMERIC NOT NULL, "chain_id" INTEGER NOT NULL, PRIMARY KEY("id", "chain_id"));`,
      ` AND "chain_id" = $2`,
      true,
    ))
  })

  it("Keys the row schema and the getWhere filter by the API name", t => {
    let locations = switch (PgStorage.getRowSchema(snakeCounter)->S.classify: S.tagged) {
    | Object({items}) => items->Array.map(item => item.location)
    | _ => []
    }
    // The stamped entity is keyed by `chainId`; only the SQL layer renames it.
    t.expect((
      locations,
      snakeCounter.table
      ->Table.queryFields
      ->Dict.get("chainId")
      ->Option.map(f => f.pgDbFieldName),
    )).toEqual((["id", "count", "chainId"], Some("chain_id")))
  })
})

describe("Per-chain ClickHouse view", () => {
  it("Dedups the current state per (id, chain id)", t => {
    t.expect((
      ClickHouse.makeCreateViewQuery(~entityConfig=counter, ~database="db")->String.includes(
        "LIMIT 1 BY `id`, `chainId`",
      ),
      ClickHouse.makeCreateViewQuery(~entityConfig=globalCounter, ~database="db")->String.includes(
        "LIMIT 1 BY `id`\n",
      ),
    )).toEqual((true, true))
  })
})

// The ClickHouse sink caches a compiled serializer per (entity, scope) because
// a DELETE row carries no entity to stamp — the chain id is baked into the
// schema instead. A cache keyed only by entity would serve chain 1's schema to
// chain 137.
type capturedInsert = {table: string, values: array<JSON.t>}

describe("Per-chain ClickHouse writes", () => {
  let insertAndCapture = async (~changes, ~entityConfig, ~scope, ~cache) => {
    let captured = []
    let client =
      {
        "insert": params => {
          captured
          ->Array.push({
            table: params["table"],
            values: params["values"]->(Utils.magic: unknown => array<JSON.t>),
          }: capturedInsert)
          ->ignore
          Promise.resolve()
        },
      }->(Utils.magic: {..} => ClickHouse.client)
    await ClickHouse.setUpdatesOrThrow(client, ~cache, ~changes, ~entityConfig, ~scope, ~database="db")
    captured
  }

  let set = (~id, ~count): Change.t<Internal.entity> =>
    Set({
      entityId: id->EntityId.unsafeOfString,
      checkpointId: 1n,
      entity: {"id": id, "count": count}->(Utils.magic: {..} => Internal.entity),
    })

  let delete = (~id): Change.t<Internal.entity> =>
    Delete({entityId: id->EntityId.unsafeOfString, checkpointId: 2n})

  Async.it("Stamps set rows and tags delete rows with the flush group's chain", async t => {
    let cache = Dict.make()
    let chain1 = await insertAndCapture(
      ~changes=[set(~id="a", ~count=1n), delete(~id="b")],
      ~entityConfig=counter,
      ~scope=Chain(1->ChainId.fromInt),
      ~cache,
    )
    // Same cache, different scope: a per-entity cache would reuse chain 1's
    // schema and tag the delete row with chain 1.
    let chain137 = await insertAndCapture(
      ~changes=[set(~id="a", ~count=2n), delete(~id="b")],
      ~entityConfig=counter,
      ~scope=Chain(137->ChainId.fromInt),
      ~cache,
    )

    let chainIds = captured =>
      captured
      ->Array.flatMap(c => c.values)
      ->Array.map(v =>
        v->(Utils.magic: JSON.t => {"chainId": option<int>})->(o => o["chainId"])
      )

    t.expect((chain1->chainIds, chain137->chainIds)).toEqual((
      [Some(1), Some(1)],
      [Some(137), Some(137)],
    ))
  })

  Async.it("Leaves a cross-chain entity's rows without a chain id", async t => {
    let captured = await insertAndCapture(
      ~changes=[set(~id="a", ~count=1n), delete(~id="b")],
      ~entityConfig=globalCounter,
      ~scope=CrossChain,
      ~cache=Dict.make(),
    )
    t.expect(
      captured
      ->Array.flatMap(c => c.values)
      ->Array.map(v => v->(Utils.magic: JSON.t => {"chainId": option<int>})->(o => o["chainId"])),
    ).toEqual([None, None])
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
      Hasura.makeColumnMapping(~relationalKey="counter_id", ~isDerivedFrom=true, ~chainIdColumn=None),
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

  it("Adds the chain id to the row schema of a per-chain entity only", t => {
    let locations = entityConfig =>
      switch (PgStorage.getRowSchema(entityConfig)->S.classify: S.tagged) {
      | Object({items}) => items->Array.map(item => item.location)
      | _ => []
      }
    t.expect((counter->locations, globalCounter->locations)).toEqual((
      ["id", "count", "chainId"],
      ["id", "count"],
    ))
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
      (makeEffect()).crossChain,
      (makeEffect(~crossChain=true)).crossChain,
      (makeEffect(~crossChain=false)).crossChain,
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
    Core.fromUserApi(
      ~schema,
      configYaml(~disableDefaultCrossChain),
    ).config->JSON.parseOrThrow

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
    t.expect((
      json->key("defaultCrossChain"),
      json->entityKey("Counter", "crossChain"),
    )).toEqual((None, None))
  })

  it("Emits only the scopes that differ from the resolved default", t => {
    let json = publicJson(~schema, ~disableDefaultCrossChain=true)
    t.expect((
      json->key("defaultCrossChain"),
      json->entityKey("Counter", "crossChain"),
      json->entityKey("GlobalCounter", "crossChain"),
    )).toEqual((
      Some(JSON.Encode.bool(false)),
      None,
      Some(JSON.Encode.bool(true)),
    ))
  })
})
