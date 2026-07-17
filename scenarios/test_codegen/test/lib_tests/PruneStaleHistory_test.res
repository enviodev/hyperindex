open Vitest

let makeEntityConfig = (~name, ~postgres=true, ~clickhouse=false): Internal.entityConfig =>
  {
    "name": name,
    "index": 0,
    "storage": {"postgres": postgres, "clickhouse": clickhouse},
  }->(
    Utils.magic: {"name": string, "index": int, "storage": {"postgres": bool, "clickhouse": bool}} => Internal.entityConfig
  )

let toNames = (targets: PruneStaleHistory.targets) => {
  "concurrent": targets.concurrent->Array.map(entityConfig => entityConfig.name),
  "forced": targets.forced->Array.map(entityConfig => entityConfig.name),
}

let intervalMillis = 1000.
let nowMillis = 100_000.

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
      ~allEntities=["recent", "written", "never", "oldA", "oldB", "oldC", "oldD"]->Array.map(name =>
        makeEntityConfig(~name)
      ),
      ~lastPrunedAtMillis,
      ~writtenEntityNames=Utils.Set.fromArray(["written"]),
      ~isRollback=false,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpointId=100n,
    )

    t.expect({
      "safeCheckpointId": targets.safeCheckpointId,
      "concurrent": (targets->toNames)["concurrent"],
      "forced": (targets->toNames)["forced"],
    }).toEqual({
      "safeCheckpointId": 100n,
      "concurrent": ["never", "oldA", "oldB", "oldC", "oldD"],
      "forced": [],
    })
  })

  it("Caps concurrent at 5 and force-prunes starved entities, even ones written in the batch", t => {
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
      ~allEntities=["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"]->Array.map(name =>
        makeEntityConfig(~name)
      ),
      ~lastPrunedAtMillis,
      ~writtenEntityNames=Utils.Set.fromArray(["e1", "e2"]),
      ~isRollback=false,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpointId=100n,
    )

    t.expect(targets->toNames).toEqual({
      "concurrent": ["e3", "e4", "e5", "e6", "e7"],
      "forced": ["e1", "e2", "e8"],
    })
  })

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
      ~allEntities=["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"]->Array.map(name =>
        makeEntityConfig(~name)
      ),
      ~lastPrunedAtMillis,
      ~writtenEntityNames=Utils.Set.make(),
      ~isRollback=true,
      ~nowMillis,
      ~intervalMillis,
      ~safeCheckpointId=100n,
    )

    t.expect(targets->toNames).toEqual({
      "concurrent": [],
      "forced": ["e1", "e2", "e3", "e4", "e5"],
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
      ~safeCheckpointId=100n,
    )

    t.expect(targets->toNames).toEqual({
      "concurrent": ["pg"],
      "forced": [],
    })
  })
})
