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
        manager->IndexManager.isSatisfied(ownerId),
        manager->IndexManager.prepare(~definition=ownerId, ~pgSchema)->Option.isNone,
      ),
      ~message="A valid legacy index is kept, not duplicated under a generated name",
    ).toEqual((true, true))
  })

  Async.it("Plans a plain create when nothing holds the generated name", async t => {
    let manager = IndexManager.make()
    let prepared = manager->IndexManager.prepare(~definition=ownerId, ~pgSchema)->Option.getOrThrow

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
    let prepared = manager->IndexManager.prepare(~definition=ownerId, ~pgSchema)->Option.getOrThrow

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
      () => manager->IndexManager.prepare(~definition=ownerId, ~pgSchema),
      ~message="A unique index isn't one the indexer created, so it is never dropped",
    ).toThrow()
  })
})

describe("Verifying a build against the catalog", () => {
  let prepare = () => {
    let manager = IndexManager.make()
    (manager, manager->IndexManager.prepare(~definition=ownerId, ~pgSchema)->Option.getOrThrow)
  }

  Async.it("Records the index only once PostgreSQL reports it back as usable", async t => {
    let (manager, prepared) = prepare()
    let entry = prepared->IndexManager.verifyOrThrow(
      ~rows=[makeRow(~tableName="Token", ~indexName=prepared.name, ~columns=["owner_id"])],
      ~pgSchema,
    )
    manager->IndexManager.record(entry)

    t.expect((manager->names, manager->IndexManager.isSatisfied(ownerId))).toEqual((
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

  Async.it("Replaces the whole catalog on reload, so a restart is authoritative", async t => {
    let manager = IndexManager.make()
    await manager->build(~definition=ownerId, ~run=() => Promise.resolve())
    let _ = manager->IndexManager.reload(
      ~rows=[makeRow(~tableName="Token", ~indexName="Token_minted_at", ~columns=["minted_at"])],
    )

    t.expect((manager->names, manager->IndexManager.isSatisfied(ownerId))).toEqual((
      ["Token_minted_at"],
      false,
    ))
  })
})
