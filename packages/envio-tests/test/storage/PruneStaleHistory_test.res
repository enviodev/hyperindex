open Vitest

let makeEntityConfig = (~name, ~postgres=true, ~clickhouse=false): Internal.entityConfig =>
  {
    "name": name,
    "index": 0,
    "storage": {"postgres": postgres, "clickhouse": clickhouse},
  }->(
    Utils.magic: {
      "name": string,
      "index": int,
      "storage": {"postgres": bool, "clickhouse": bool},
    } => Internal.entityConfig
  )

let summary = (targets: PruneStaleHistory.targets) =>
  {
    "concurrent": targets.concurrent->Array.map(entityConfig => entityConfig.name),
    "forced": targets.forced->Array.map(entityConfig => entityConfig.name),
    "checkpoints": targets.checkpoints,
    "isRollback": targets.isRollback,
  }

let intervalMillis = 1000.
let nowMillis = 100_000.
let safeCheckpoints = {
  CheckpointSequence.sequence: SharedAcrossChains,
  byChain: Frontier.fromEntries([(1->ChainId.fromInt, 100n)]),
}

describe("PruneStaleHistory.selectFrom", () => {
  it("Selects up to 5 overdue entities oldest-first, excluding ones written in the batch", t => {
    let lastPrunedAtMillis = Dict.fromArray([
      ("recent", 99_500.),
      ("written", 95_500.),
      ("oldA", 95_000.),
      ("oldB", 96_000.),
      ("oldC", 97_000.),
      ("oldD", 99_000.),
    ])

    let targets = PruneStaleHistory.selectFrom(
      ~allEntities=["recent", "written", "never", "oldA", "oldB", "oldC", "oldD"]->Array.map(
        name => makeEntityConfig(~name),
      ),
      ~lastPrunedAtMillis,
      ~writtenEntityNames=Utils.Set.fromArray(["written"]),
      ~isRollback=false,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpoints,
    )

    t.expect((targets.safeCheckpoints, targets->summary)).toEqual((
      safeCheckpoints,
      {
        "concurrent": ["never", "oldA", "oldB", "oldC", "oldD"],
        "forced": [],
        "checkpoints": true,
        "isRollback": false,
      },
    ))
  })

  it(
    "Caps concurrent at 5 and force-prunes starved entities, even ones written in the batch",
    t => {
      let lastPrunedAtMillis = Dict.fromArray([
        ("e2", 10_000.),
        ("e3", 20_000.),
        ("e4", 30_000.),
        ("e5", 40_000.),
        ("e6", 50_000.),
        ("e7", 60_000.),
        ("e8", 70_000.),
      ])

      let targets = PruneStaleHistory.selectFrom(
        ~allEntities=["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"]->Array.map(
          name => makeEntityConfig(~name),
        ),
        ~lastPrunedAtMillis,
        ~writtenEntityNames=Utils.Set.fromArray(["e1", "e2"]),
        ~isRollback=false,
        ~nowMillis,
        ~intervalMillis,
        ~safeCheckpoints,
      )

      t.expect(targets->summary).toEqual({
        "concurrent": ["e3", "e4", "e5", "e6", "e7"],
        "forced": ["e1", "e2", "e8"],
        "checkpoints": true,
        "isRollback": false,
      })
    },
  )

  it("Selects no concurrent prunes for a rollback write, but keeps forced ones", t => {
    let lastPrunedAtMillis = Dict.fromArray([
      ("e2", 10_000.),
      ("e3", 20_000.),
      ("e4", 30_000.),
      ("e5", 40_000.),
      ("e6", 50_000.),
      ("e7", 60_000.),
      ("e8", 70_000.),
    ])

    let targets = PruneStaleHistory.selectFrom(
      ~allEntities=["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"]->Array.map(
        name => makeEntityConfig(~name),
      ),
      ~lastPrunedAtMillis,
      ~writtenEntityNames=Utils.Set.make(),
      ~isRollback=true,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpoints,
    )

    t.expect(targets->summary).toEqual({
      "concurrent": [],
      "forced": ["e1", "e2", "e3", "e4", "e5"],
      "checkpoints": true,
      "isRollback": true,
    })
  })

  it("Skips entities not stored in postgres", t => {
    let targets = PruneStaleHistory.selectFrom(
      ~allEntities=[
        makeEntityConfig(~name="pg"),
        makeEntityConfig(~name="chOnly", ~postgres=false, ~clickhouse=true),
      ],
      ~lastPrunedAtMillis=Dict.make(),
      ~writtenEntityNames=Utils.Set.make(),
      ~isRollback=false,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpoints,
    )

    t.expect(targets->summary).toEqual({
      "concurrent": ["pg"],
      "forced": [],
      "checkpoints": true,
      "isRollback": false,
    })
  })

  // With every entity in ClickHouse, Postgres has no history to prune the
  // checkpoints beside, so they keep an interval of their own.
  it("Prunes the checkpoints once their own interval is up, with no entity to prune", t => {
    let select = (~lastPrunedAtMillis) =>
      PruneStaleHistory.selectFrom(
        ~allEntities=[makeEntityConfig(~name="chOnly", ~postgres=false, ~clickhouse=true)],
        ~lastPrunedAtMillis,
        ~writtenEntityNames=Utils.Set.make(),
        ~isRollback=false,
        ~nowMillis,
        ~intervalMillis,
        ~safeCheckpoints,
      )->summary

    t.expect((
      select(~lastPrunedAtMillis=Dict.fromArray([(PruneStaleHistory.checkpointsKey, 99_500.)])),
      select(~lastPrunedAtMillis=Dict.fromArray([(PruneStaleHistory.checkpointsKey, 98_000.)])),
    )).toEqual((
      {"concurrent": [], "forced": [], "checkpoints": false, "isRollback": false},
      {"concurrent": [], "forced": [], "checkpoints": true, "isRollback": false},
    ))
  })
})
