open Vitest

let makeRow = (
  ~tableName,
  ~indexName,
  ~columns,
  ~directions=?,
  ~method="btree",
  ~isValid=1,
  ~isPlain=1,
): IndexRegistry.catalogRow => {
  tableName,
  indexName,
  method,
  isValid,
  isPlain,
  columns,
  directions: switch directions {
  | Some(directions) => directions
  | None => columns->Array.map(_ => "ASC")
  },
}

// Builds are chained off a promise, so they start on a later microtask.
let tick = async () => {
  for _ in 0 to 3 {
    let _ = await Promise.resolve()
  }
}

describe("IndexRegistry", () => {
  Async.it("Keys an index by table, method and ordered columns with direction", async t => {
    t.expect((
      IndexRegistry.makeKey(
        ~tableName="Token",
        ~columns=[{name: "owner_id", direction: Table.Asc}],
        ~method=IndexRegistry.btree,
      ),
      IndexRegistry.makeKey(
        ~tableName="Transfer",
        ~columns=[
          {name: "block_number", direction: Table.Desc},
          {name: "log_index", direction: Table.Asc},
        ],
        ~method=IndexRegistry.btree,
      ),
    )).toEqual(("Token|btree|owner_id", "Transfer|btree|block_number DESC,log_index"))
  })

  Async.it("Distinguishes column order, direction and access method", async t => {
    let key = (~columns, ~method) =>
      IndexRegistry.makeKey(~tableName="Transfer", ~columns, ~method)
    let a: IndexRegistry.column = {name: "a", direction: Table.Asc}
    let b: IndexRegistry.column = {name: "b", direction: Table.Asc}

    t.expect(
      [
        key(~columns=[a, b], ~method="btree"),
        key(~columns=[b, a], ~method="btree"),
        key(~columns=[a, b], ~method="hash"),
        key(~columns=[{...a, direction: Table.Desc}, b], ~method="btree"),
      ]->Set.fromArray->Set.size,
      ~message="Each variation must be a distinct index identity",
    ).toBe(4)
  })

  Async.it("Rediscovers existing indexes from catalog rows, ignoring invalid ones", async t => {
    let registry = IndexRegistry.make()
    let invalid = registry->IndexRegistry.reload(
      ~rows=[
        makeRow(~tableName="Token", ~indexName="Token_owner_id", ~columns=["owner_id"]),
        makeRow(
          ~tableName="Transfer",
          ~indexName="Transfer_block_number_desc_log_index",
          ~columns=["block_number", "log_index"],
          ~directions=["DESC", "ASC"],
        ),
        makeRow(
          ~tableName="Token",
          ~indexName="Token_broken",
          ~columns=["broken"],
          ~isValid=0,
        ),
      ],
    )

    t.expect((invalid, registry->IndexRegistry.toArray)).toEqual((
      ["Token_broken"],
      ["Token|btree|owner_id", "Transfer|btree|block_number DESC,log_index"],
    ))
  })

  Async.it("Replaces the whole registry on reload, so a restart is authoritative", async t => {
    let registry = IndexRegistry.make()
    registry->IndexRegistry.add("Token|btree|stale")
    let _ = registry->IndexRegistry.reload(
      ~rows=[makeRow(~tableName="Token", ~indexName="Token_owner_id", ~columns=["owner_id"])],
    )

    t.expect(registry->IndexRegistry.toArray).toEqual(["Token|btree|owner_id"])
  })

  Async.it("Builds a missing index once and registers it on success", async t => {
    let registry = IndexRegistry.make()
    let builds = []
    let build = () => {
      builds->Array.push("Token_owner_id")->ignore
      Promise.resolve()
    }

    await registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build,
    )
    await registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build,
    )

    t.expect(
      (builds, registry->IndexRegistry.toArray),
      ~message="The second request is served from the registry, with no second build",
    ).toEqual((["Token_owner_id"], ["Token|btree|owner_id"]))
  })

  Async.it("Shares one build between concurrent identical requests", async t => {
    let registry = IndexRegistry.make()
    let buildCount = ref(0)
    let resolveBuild = ref(() => ())
    let build = () => {
      buildCount := buildCount.contents + 1
      Promise.make((resolve, _) => resolveBuild := (() => resolve()))
    }

    let first = registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build,
    )
    let second = registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build,
    )

    await tick()
    t.expect(buildCount.contents, ~message="Only one build is started").toBe(1)

    resolveBuild.contents()
    await first
    await second

    t.expect((buildCount.contents, registry->IndexRegistry.toArray)).toEqual((
      1,
      ["Token|btree|owner_id"],
    ))
  })

  Async.it("Serializes different builds on the same table", async t => {
    let registry = IndexRegistry.make()
    let started = []
    let resolvers = Dict.make()
    let build = column => () => {
      started->Array.push(column)->ignore
      Promise.make((resolve, _) => resolvers->Dict.set(column, () => resolve()))
    }

    let owner = registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build=build("owner_id"),
    )
    let minted = registry->IndexRegistry.ensure(
      ~key="Token|btree|minted_at",
      ~tableName="Token",
      ~build=build("minted_at"),
    )

    await tick()
    t.expect(started, ~message="The second build waits for the first").toEqual(["owner_id"])

    let resolveOwner = resolvers->Dict.getUnsafe("owner_id")
    resolveOwner()
    await owner
    await tick()
    t.expect(started, ~message="The second build starts once the first finished").toEqual([
      "owner_id",
      "minted_at",
    ])

    let resolveMinted = resolvers->Dict.getUnsafe("minted_at")
    resolveMinted()
    await minted
    t.expect(registry->IndexRegistry.toArray).toEqual([
      "Token|btree|minted_at",
      "Token|btree|owner_id",
    ])
  })

  Async.it("Leaves the registry untouched when a build fails, and retries after", async t => {
    let registry = IndexRegistry.make()
    let shouldFail = ref(true)
    let build = () =>
      if shouldFail.contents {
        Promise.reject(Utils.Error.make("permission denied"))
      } else {
        Promise.resolve()
      }

    let failed = await registry
    ->IndexRegistry.ensure(~key="Token|btree|owner_id", ~tableName="Token", ~build)
    ->Promise.thenResolve(() => false)
    ->Utils.Promise.catchResolve(_ => true)

    t.expect(
      (failed, registry->IndexRegistry.toArray),
      ~message="A failed DDL must not add the index to the registry",
    ).toEqual((true, []))

    shouldFail := false
    await registry->IndexRegistry.ensure(
      ~key="Token|btree|owner_id",
      ~tableName="Token",
      ~build,
    )

    t.expect(registry->IndexRegistry.toArray).toEqual(["Token|btree|owner_id"])
  })

  Async.it("Rejects index names that truncate to the same identifier", async t => {
    let prefix = "Entity_" ++ "x"->String.repeat(56)

    t.expect(
      () => IndexRegistry.validateIndexNamesOrThrow([prefix ++ "_one", prefix ++ "_two"]),
      ~message="Two descriptions may not silently truncate to the same index name",
    ).toThrow()

    t.expect(
      () => IndexRegistry.validateIndexNamesOrThrow(["Token_owner_id", "Transfer_block_number"]),
      ~message="Distinct short names are fine",
    ).not.toThrow()
  })
})
