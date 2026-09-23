open Vitest

// The effect cache leaves the database as TSV and comes back the same way:
// `dumpEffectCache` copies it out to a file and the upload that `initialize`
// runs copies it back in. What a developer does between two `envio dev -r` runs
// is this round trip, and nothing exercised it.

let sql = PgStorage.makeClient()

let config = TestConfig.make(
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)
let entities = [config->IndexerRunner.entityConfigByName("Counter")]
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])

// One cache per scope: they are the same round trip through different paths —
// `<name>.tsv` at the top of the cache directory, `<chainId>/<name>.tsv` below
// it.
let crossChain = Internal.makeCacheTable(~effectName="priceOf", ~scope=CrossChain)
let perChain = Internal.makeCacheTable(~effectName="priceOf", ~scope=Chain(1->ChainId.fromInt))

let cacheItemSchema = S.object(s => {
  let dict = Dict.make()
  dict->Dict.set("id", s.field("id", S.string->S.toUnknown))
  dict->Dict.set("output", s.field("output", S.json(~validate=false)->S.toUnknown))
  dict
})->S.toUnknown

let cacheRow = (~id, ~output) => {
  let row = Dict.make()
  row->Dict.set("id", id->(Utils.magic: string => unknown))
  row->Dict.set("output", output->(Utils.magic: JSON.t => unknown))
  row
}

let storageFor = pgSchema =>
  PgStorage.make(~sql, ~pgSchema, ~pgUser=Env.Db.user, ~isHasuraEnabled=false, ~ecosystem=Evm)

let initialize = (storage: Persistence.storage) =>
  storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~entities,
    ~enums,
    ~envioInfo=JSON.parseOrThrow(`{"name": "effect-cache"}`),
  )

let seed = async (~pgSchema, ~table: Table.table, ~rows) => {
  await sql->Sql.batch(
    PgStorage.makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false),
  )
  await sql->PgStorage.setOrThrow(
    ~items=rows->(Utils.magic: array<dict<unknown>> => array<unknown>),
    ~table,
    ~itemSchema=cacheItemSchema,
    ~pgSchema,
    ~setQueryCache=PgStorage.makeSetQueryCache(),
  )
}

let read = async (~pgSchema, ~table: Table.table) =>
  (await sql->Sql.query(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=table.tableName)))
  ->(Utils.magic: array<unknown> => array<dict<unknown>>)
  ->Array.map(row => (
    row->Dict.getUnsafe("id")->(Utils.magic: unknown => string),
    row->Dict.getUnsafe("output")->(Utils.magic: unknown => JSON.t)->JSON.stringify,
  ))

let dumped = TestPgSchema.make()
let restored = TestPgSchema.make()
// Where `dumpEffectCache` writes, which is the project root and not a path the
// storage takes as an argument.
let cacheDir = NodeJs.Path.resolve([".envio", "cache"])

Async.afterAll(async () => {
  await TestPgSchema.drop(sql, ~pgSchema=dumped)
  await TestPgSchema.drop(sql, ~pgSchema=restored)
  await NodeJs.Fs.Promises.rm(cacheDir, ~options={recursive: true, force: true})
  await sql->Sql.close
})

describe("The effect cache leaving and re-entering the database", () => {
  Async.it("comes back into a schema built after it was written out", async t => {
    let storage = storageFor(dumped)
    let _ = await initialize(storage)
    await seed(
      ~pgSchema=dumped,
      ~table=crossChain,
      ~rows=[
        cacheRow(~id="usdc", ~output=JSON.parseOrThrow(`{"price": "1.00"}`)),
        // A tab and a newline are what a TSV uses for its own structure, so a
        // value carrying them is the one that says whether the copy is quoted.
        cacheRow(~id="weth", ~output=JSON.parseOrThrow(`{"note": "a\\tb\\nc"}`)),
      ],
    )
    await seed(
      ~pgSchema=dumped,
      ~table=perChain,
      ~rows=[cacheRow(~id="dai", ~output=JSON.parseOrThrow(`{"price": "0.99"}`))],
    )

    await storage.dumpEffectCache()

    let written = (await NodeJs.Fs.Promises.readdir(cacheDir))->Array.toSorted(String.compare)

    let state = await initialize(storageFor(restored))
    let counts =
      state.cache
      ->Dict.toArray
      ->Array.map(((name, record)) => (name, record.count))
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

    t.expect((
      written,
      counts,
      await read(~pgSchema=restored, ~table=crossChain),
      await read(~pgSchema=restored, ~table=perChain),
    )).toEqual((
      ["1", "priceOf.tsv"],
      [("envio_1_effect_priceOf", 1), ("envio_effect_priceOf", 2)],
      // Re-serialized, so without the spacing the seed was written with, and
      // with the tab and the newline back as themselves.
      [("usdc", `{"price":"1.00"}`), ("weth", `{"note":"a\\tb\\nc"}`)],
      [("dai", `{"price":"0.99"}`)],
    ))
  })
})
