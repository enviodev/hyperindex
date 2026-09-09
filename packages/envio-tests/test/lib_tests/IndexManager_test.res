open Vitest

let makeRow = IndexFixtures.makeRow

let pgSchema = "test_schema"

let ownerId = IndexDefinition.single(~tableName="Token", ~column="owner_id")
let mintedAt = IndexDefinition.single(~tableName="Token", ~column="minted_at")

// Builds are chained off a promise, so they start on a later microtask.
let tick = async () => {
  for _ in 0 to 3 {
    let _ = await Promise.resolve()
  }
}

let names = manager =>
  manager
  ->IndexManager.catalog
  ->IndexCatalog.entries
  ->Array.map((entry: IndexCatalog.entry) => entry.name)
  ->Array.toSorted(String.compare)

let catch = promise =>
  promise
  ->Promise.thenResolve(_ => None)
  ->Utils.Promise.catchResolve(exn =>
    Some(exn->(Utils.magic: exn => {"message": string})->(error => error["message"]))
  )

describe("Planning a build", () => {
  Async.it("Skips the build when the catalog already covers the identity", async t => {
    let manager = IndexManager.make()
    let _ = manager->IndexManager.reload(
      ~rows=[makeRow(~tableName="Token", ~indexName="Token_owner_id", ~columns=["owner_id"])],
    )

    t.expect(
      (
        manager->IndexManager.isSatisfied(ownerId, ~coverage=LeadingColumns),
        manager->IndexManager.prepare(~definition=ownerId, ~coverage=LeadingColumns, ~pgSchema)->Option.isNone,
      ),
      ~message="A valid legacy index is kept, not duplicated under a generated name",
    ).toEqual((true, true))
  })

  Async.it("Plans a plain create when nothing holds the generated name", async t => {
    let manager = IndexManager.make()
    let prepared = manager->IndexManager.prepare(~definition=ownerId, ~coverage=LeadingColumns, ~pgSchema)->Option.getOrThrow

    t.expect((prepared.name, prepared.isRebuild, prepared.queries)).toEqual((
      ownerId->IndexDefinition.name,
      false,
      [ownerId->IndexDefinition.makeCreateQuery(~pgSchema)],
    ))
  })

  // The name embeds a hash of the identity, so an invalid index holding it with
  // exactly that identity can only be one the indexer built. Dropping and
  // rebuilding is safe there — and nowhere else.
  Async.it("Drops and rebuilds an invalid index it can prove is its own", async t => {
    let manager = IndexManager.make()
    let name = ownerId->IndexDefinition.name
    let _ = manager->IndexManager.reload(
      ~rows=[
        makeRow(~tableName="Token", ~indexName=name, ~columns=["owner_id"], ~isValid=0),
      ],
    )
    let prepared = manager->IndexManager.prepare(~definition=ownerId, ~coverage=LeadingColumns, ~pgSchema)->Option.getOrThrow

    t.expect((prepared.isRebuild, prepared.queries)).toEqual((
      true,
      [
        IndexDefinition.makeDropQuery(~pgSchema, ~indexName=name),
        ownerId->IndexDefinition.makeCreateQuery(~pgSchema),
      ],
    ))
  })

  Async.it("Refuses to touch an index that only shares the name", async t => {
    let manager = IndexManager.make()
    let _ = manager->IndexManager.reload(
      ~rows=[
        makeRow(
          ~tableName="Token",
          ~indexName=ownerId->IndexDefinition.name,
          ~columns=["owner_id"],
          ~isUnique=1,
          ~isValid=0,
        ),
      ],
    )

    t.expect(
      () => manager->IndexManager.prepare(~definition=ownerId, ~coverage=LeadingColumns, ~pgSchema),
      ~message="A unique index isn't one the indexer created, so it is never dropped",
    ).toThrow()
  })
})

describe("Reconciling a declared schema", () => {
  let single = IndexDefinition.single(~tableName="Token", ~column="a")
  let composite = IndexDefinition.make(
    ~tableName="Token",
    ~columns=[{name: "a", direction: Table.Asc}, {name: "b", direction: Table.Asc}],
  )
  let compositeRow = makeRow(
    ~tableName="Token",
    ~indexName=composite->IndexDefinition.name,
    ~columns=["a", "b"],
  )

  // What the schema declares, in the order getSchemaIndexes yields it.
  let declared = [single, composite]

  let namesAfterReconciling = (~rows) => {
    let manager = IndexManager.make()
    let _ = manager->IndexManager.reload(~rows)
    rows
    ->Array.map((row: IndexCatalog.row) => row.indexName)
    ->Array.concat(
      declared
      ->Array.filterMap(definition =>
        manager->IndexManager.prepare(~definition, ~coverage=Exact, ~pgSchema)
      )
      ->Array.map((prepared: IndexManager.prepared) => prepared.name),
    )
    ->Array.toSorted(String.compare)
  }

  // The composite leads with `a`, so matching declared indexes by leading
  // columns would skip the single-column index on a database that already has
  // the composite, while a fresh database built both. Same schema, different
  // tables — and no way to tell from the schema which one you have.
  Async.it("Reaches the same indexes on a fresh and on an upgraded database", async t => {
    let expected =
      [single->IndexDefinition.name, composite->IndexDefinition.name]->Array.toSorted(
        String.compare,
      )

    t.expect((
      namesAfterReconciling(~rows=[]),
      namesAfterReconciling(~rows=[compositeRow]),
    )).toEqual((expected, expected))
  })

  // The optimization is still there where it's safe: nobody declared the
  // automatic index, so an existing composite is good enough for it.
  Async.it("Still lets a composite serve an automatic request for its lead column", async t => {
    let manager = IndexManager.make()
    let _ = manager->IndexManager.reload(~rows=[compositeRow])

    t.expect((
      manager->IndexManager.isSatisfied(single, ~coverage=LeadingColumns),
      manager->IndexManager.isSatisfied(single, ~coverage=Exact),
    )).toEqual((true, false))
  })
})

describe("Verifying a build against the catalog", () => {
  let prepare = () => {
    let manager = IndexManager.make()
    (manager, manager->IndexManager.prepare(~definition=ownerId, ~coverage=LeadingColumns, ~pgSchema)->Option.getOrThrow)
  }

  Async.it("Records the index only once PostgreSQL reports it back as usable", async t => {
    let (manager, prepared) = prepare()
    let entry = prepared->IndexManager.verifyOrThrow(
      ~rows=[makeRow(~tableName="Token", ~indexName=prepared.name, ~columns=["owner_id"])],
      ~pgSchema,
    )
    manager->IndexManager.record(entry)

    t.expect((manager->names, manager->IndexManager.isSatisfied(ownerId, ~coverage=LeadingColumns))).toEqual((
      [prepared.name],
      true,
    ))
  })

  // `CREATE INDEX IF NOT EXISTS` on a taken name succeeds without building
  // anything. Reading the index back is what turns that into a failure.
  Async.it("Fails when the DDL succeeded but left no such index", async t => {
    let (manager, prepared) = prepare()
    let message = switch prepared->IndexManager.verifyOrThrow(~rows=[], ~pgSchema) {
    | _ => ""
    | exception exn =>
      exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string})->(error => error["message"])
    }

    t.expect(
      (message->String.includes("PostgreSQL has no such index"), manager->names),
      ~message="Nothing is recorded, so the next pass tries again",
    ).toEqual((true, []))
  })

  Async.it("Fails when the built index came back unusable", async t => {
    let (_, prepared) = prepare()
    let message = switch prepared->IndexManager.verifyOrThrow(
      ~rows=[
        makeRow(
          ~tableName="Token",
          ~indexName=prepared.name,
          ~columns=["owner_id"],
          ~isValid=0,
        ),
      ],
      ~pgSchema,
    ) {
    | _ => ""
    | exception exn =>
      exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string})->(error => error["message"])
    }

    t.expect(message->String.includes("invalid or not ready")).toBe(true)
  })
})

describe("Serialising builds", () => {
  let build = (manager, ~definition, ~run) =>
    manager->IndexManager.ensure(
      ~definition,
      ~coverage=LeadingColumns,
      ~build=async () => {
        await run()
        manager->IndexManager.record(
          (
            makeRow(
              ~tableName=definition.IndexDefinition.tableName,
              ~indexName=definition->IndexDefinition.name,
              ~columns=definition.columns->Array.map(c => c.IndexDefinition.name),
            )
          )->IndexCatalog.fromRow,
        )
      },
    )

  Async.it("Builds a missing index once and serves the next request from the catalog", async t => {
    let manager = IndexManager.make()
    let runs = ref(0)
    let run = () => {
      runs := runs.contents + 1
      Promise.resolve()
    }

    await manager->build(~definition=ownerId, ~run)
    await manager->build(~definition=ownerId, ~run)

    t.expect((runs.contents, manager->names)).toEqual((1, [ownerId->IndexDefinition.name]))
  })

  Async.it("Shares one build between concurrent identical requests", async t => {
    let manager = IndexManager.make()
    let runs = ref(0)
    let resolveRun = ref(() => ())
    let run = () => {
      runs := runs.contents + 1
      Promise.make((resolve, _) => resolveRun := (() => resolve()))
    }

    let first = manager->build(~definition=ownerId, ~run)
    let second = manager->build(~definition=ownerId, ~run)
    await tick()
    t.expect(runs.contents, ~message="Only one build is started").toBe(1)

    resolveRun.contents()
    await first
    await second

    t.expect((runs.contents, manager->names)).toEqual((1, [ownerId->IndexDefinition.name]))
  })

  Async.it("Serialises different builds on the same table", async t => {
    let manager = IndexManager.make()
    let started = []
    let resolvers = Dict.make()
    let run = column => () => {
      started->Array.push(column)->ignore
      Promise.make((resolve, _) => resolvers->Dict.set(column, () => resolve()))
    }

    let owner = manager->build(~definition=ownerId, ~run=run("owner_id"))
    let minted = manager->build(~definition=mintedAt, ~run=run("minted_at"))

    await tick()
    t.expect(started, ~message="The second build waits for the first").toEqual(["owner_id"])

    (resolvers->Dict.getUnsafe("owner_id"))()
    await owner
    await tick()
    t.expect(started).toEqual(["owner_id", "minted_at"])

    (resolvers->Dict.getUnsafe("minted_at"))()
    await minted

    t.expect(manager->names).toEqual(
      [ownerId->IndexDefinition.name, mintedAt->IndexDefinition.name]->Array.toSorted(
        String.compare,
      ),
    )
  })

  Async.it("Records nothing when a build fails, and retries on the next request", async t => {
    let manager = IndexManager.make()
    let shouldFail = ref(true)
    let run = () =>
      if shouldFail.contents {
        Promise.reject(Utils.Error.make("permission denied"))
      } else {
        Promise.resolve()
      }

    let failure = await manager->build(~definition=ownerId, ~run)->catch

    t.expect((failure, manager->names)).toEqual((Some("permission denied"), []))

    shouldFail := false
    await manager->build(~definition=ownerId, ~run)

    t.expect(manager->names).toEqual([ownerId->IndexDefinition.name])
  })

  // Outside a transaction the DDL can commit and the read-back still fail, so
  // the catalog would keep claiming the name is free and every later attempt
  // would replan a create that can only raise "relation already exists".
  Async.it("Resyncs a single index from the database after a failed read-back", async t => {
    let manager = IndexManager.make()
    let name = ownerId->IndexDefinition.name

    manager->IndexManager.resync(
      ~name,
      ~rows=[makeRow(~tableName="Token", ~indexName=name, ~columns=["owner_id"])],
    )
    let recovered = manager->IndexManager.prepare(
      ~definition=ownerId,
      ~coverage=Exact,
      ~pgSchema,
    )

    manager->IndexManager.resync(~name, ~rows=[])

    t.expect(
      (recovered->Option.isNone, manager->names, manager->IndexManager.isSatisfied(ownerId, ~coverage=Exact)),
      ~message="An index the database doesn't have is forgotten again, so the build retries",
    ).toEqual((true, [], false))
  })

  // Coverage answers are memoized to keep the getWhere path off a full scan of
  // the schema. A stale "nothing covers this" rebuilds an index that exists; a
  // stale "covered" skips one that was dropped and reports ready without it.
  Async.it("Never answers coverage from a stale memo", async t => {
    let manager = IndexManager.make()
    let name = ownerId->IndexDefinition.name
    let row = makeRow(~tableName="Token", ~indexName=name, ~columns=["owner_id"])

    let beforeBuild = manager->IndexManager.isSatisfied(ownerId, ~coverage=Exact)
    manager->IndexManager.record(row->IndexCatalog.fromRow)
    let afterBuild = manager->IndexManager.isSatisfied(ownerId, ~coverage=Exact)
    manager->IndexManager.resync(~name, ~rows=[])
    let afterDrop = manager->IndexManager.isSatisfied(ownerId, ~coverage=Exact)

    t.expect((beforeBuild, afterBuild, afterDrop)).toEqual((false, true, false))
  })

  // A getWhere build settles for any index leading with its column, a schema
  // index doesn't. Sharing one in-flight slot between them would let the
  // declared index resolve on the getWhere's answer and never get built.
  Async.it("Doesn't let an Exact request resolve on an in-flight LeadingColumns build", async t => {
    let manager = IndexManager.make()
    let composite = makeRow(
      ~tableName="Token",
      ~indexName="Token_owner_id_minted_at",
      ~columns=["owner_id", "minted_at"],
    )
    let exactRuns = ref(0)
    let releaseLeading = ref(() => ())

    let leading =
      manager->IndexManager.ensure(~definition=ownerId, ~coverage=LeadingColumns, ~build=async () => {
        await Promise.make((resolve, _) => releaseLeading := (() => resolve()))
        // The composite already serves the query, so nothing under the
        // generated name is created.
        manager->IndexManager.record(composite->IndexCatalog.fromRow)
      })
    let exact =
      manager->IndexManager.ensure(~definition=ownerId, ~coverage=Exact, ~build=async () => {
        exactRuns := exactRuns.contents + 1
        manager->IndexManager.record(
          makeRow(
            ~tableName="Token",
            ~indexName=ownerId->IndexDefinition.name,
            ~columns=["owner_id"],
          )->IndexCatalog.fromRow,
        )
      })

    await tick()
    releaseLeading.contents()
    await leading
    await exact

    t.expect((exactRuns.contents, manager->names)).toEqual((
      1,
      ["Token_owner_id_minted_at", ownerId->IndexDefinition.name]->Array.toSorted(String.compare),
    ))
  })

  Async.it("Replaces the whole catalog on reload, so a restart is authoritative", async t => {
    let manager = IndexManager.make()
    await manager->build(~definition=ownerId, ~run=() => Promise.resolve())
    let _ = manager->IndexManager.reload(
      ~rows=[makeRow(~tableName="Token", ~indexName="Token_minted_at", ~columns=["minted_at"])],
    )

    t.expect((manager->names, manager->IndexManager.isSatisfied(ownerId, ~coverage=LeadingColumns))).toEqual((
      ["Token_minted_at"],
      false,
    ))
  })
})
