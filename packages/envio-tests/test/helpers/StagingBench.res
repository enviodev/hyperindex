// Measures what staging a batch for ClickHouse costs on the main thread, which
// is the thread an indexer has only one of. Run it with
// `node scripts/staging-bench.mjs`.

type usage = {user: float, system: float}
@val @scope("process") external cpuUsage: unit => usage = "cpuUsage"
@val @scope("process") external cpuUsageSince: usage => usage = "cpuUsage"
type memory = {rss: float}
@val @scope("process") external memoryUsage: unit => memory = "memoryUsage"

let gcPauses: unit => int = %raw(`() => globalThis.__envioGcPauses ?? 0`)

let observeGc: PerfHooks.performanceObserverCtor => unit = %raw(`(PerformanceObserver) => {
  globalThis.__envioGcPauses = 0;
  new PerformanceObserver(list => {
    globalThis.__envioGcPauses += list.getEntries().length;
  }).observe({ entryTypes: ["gc"] });
}`)

type sample = {cpuMs: float, wallMs: float}

%%private(
  let median = (values: array<float>) => {
    let sorted = values->Array.toSorted(Float.compare)
    sorted->Array.getUnsafe(sorted->Array.length / 2)
  }
)

%%private(let hex = "0123456789abcdef")

// Deterministic filler, so two runs of the bench stage the same bytes.
%%private(
  let text = (~length, ~seed) =>
    Array.fromInitializer(~length, index =>
      hex->String.charAt(mod(index * 31 + seed, 16))
    )->Array.join("")
)

%%private(
  let blob = (~length, ~seed) =>
    Uint8Array.fromArray(Array.fromInitializer(~length, index => mod(index * 31 + seed, 256)))
)

type profile = {
  name: string,
  schema: string,
  entityName: string,
  // One row's fields, by the names the schema declares.
  row: int => dict<unknown>,
}

let profiles = [
  {
    name: "bytea-heavy",
    entityName: "Blobs",
    schema: `
type Blobs {
  id: ID!
  a: Bytes!
  b: Bytes!
  c: Bytes!
  d: Bytes!
}
`,
    row: seed =>
      Dict.fromArray([
        ("a", blob(~length=32, ~seed)->(Utils.magic: Uint8Array.t => unknown)),
        ("b", blob(~length=32, ~seed = seed + 1)->(Utils.magic: Uint8Array.t => unknown)),
        ("c", blob(~length=128, ~seed = seed + 2)->(Utils.magic: Uint8Array.t => unknown)),
        ("d", blob(~length=20, ~seed = seed + 3)->(Utils.magic: Uint8Array.t => unknown)),
      ]),
  },
  {
    name: "string-heavy",
    entityName: "Texts",
    schema: `
type Texts {
  id: ID!
  a: String!
  b: String!
  c: String!
  d: String!
}
`,
    row: seed =>
      Dict.fromArray([
        ("a", text(~length=42, ~seed)->(Utils.magic: string => unknown)),
        ("b", text(~length=42, ~seed = seed + 1)->(Utils.magic: string => unknown)),
        ("c", text(~length=160, ~seed = seed + 2)->(Utils.magic: string => unknown)),
        ("d", text(~length=12, ~seed = seed + 3)->(Utils.magic: string => unknown)),
      ]),
  },
  {
    name: "numeric-only",
    entityName: "Numbers",
    schema: `
type Numbers {
  id: ID!
  a: Int!
  b: Float!
  c: Int!
  d: Float!
}
`,
    row: seed =>
      Dict.fromArray([
        ("a", seed->(Utils.magic: int => unknown)),
        ("b", (seed->Int.toFloat *. 1.5)->(Utils.magic: float => unknown)),
        ("c", (seed * 7)->(Utils.magic: int => unknown)),
        ("d", (seed->Int.toFloat /. 3.)->(Utils.magic: float => unknown)),
      ]),
  },
]

let rowsPerBatch = 5000
let warmupBatches = 3
let measuredBatches = 25

%%private(
  let changesFor = (profile, ~batch) =>
    Array.fromInitializer(~length=rowsPerBatch, row => {
      let seed = batch * rowsPerBatch + row
      let id = `id-${seed->Int.toString}`
      let fields = profile.row(seed)
      fields->Dict.set("id", id->(Utils.magic: string => unknown))
      Change.Set({
        entityId: id->(Utils.magic: string => EntityId.t),
        checkpointId: BigInt.fromInt(seed + 1),
        entity: fields->(Utils.magic: dict<unknown> => Internal.entity),
      })
    })
)

%%private(
  let measure = async profile => {
    let database = TestClickHouse.make()
    TestClickHouse.use(~database)
    let config = InternalTestIndexer.fromUserApi(
      ~schema=profile.schema,
      ~configYaml=`
name: staging-bench
bytes_type: uint8array
disable_default_cross_chain: true
storage:
  postgres:
    default: true
  clickhouse:
    default: true
chains:
  - id: 1
    start_block: 0
`,
    ).config
    let entityConfig = config.userEntitiesByName->Dict.getUnsafe(profile.entityName)
    let sink = ClickHouse.makeSink(
      ~host=TestClickHouse.host(),
      ~username=TestClickHouse.username(),
      ~password=TestClickHouse.password(),
      ~database,
      ~chainIdMode=Int32,
    )
    await ClickHouse.initialize(sink, ~entities=[entityConfig])
    let registry = ClickHouse.makeRegistry()

    let samples = []
    for batch in 0 to warmupBatches + measuredBatches - 1 {
      let changes = changesFor(profile, ~batch)
      let startedCpu = cpuUsage()
      let startedWall = Date.now()
      let handle = ClickHouse.stageUpdatesOrThrow(
        sink,
        ~registry,
        ~changes,
        ~entityConfig,
        ~scope=Chain(ChainId.fromInt(1)),
      )
      let staged = cpuUsageSince(startedCpu)
      await ClickHouse.writeStagedOrThrow(
        sink,
        ~entities=switch handle {
        | Some(handle) => [handle]
        | None => []
        },
        ~checkpoints=Null.null,
      )
      if batch >= warmupBatches {
        samples->Array.push({
          cpuMs: (staged.user +. staged.system) /. 1000.,
          wallMs: Date.now() -. startedWall,
        })
      }
    }
    await TestClickHouse.drop(~database)
    (
      profile.name,
      median(samples->Array.map(({cpuMs}) => cpuMs)),
      median(samples->Array.map(({wallMs}) => wallMs)),
    )
  }
)

let run = async () => {
  observeGc(PerfHooks.performanceObserver)
  let peakRss = ref(0.)
  let watch = () => {
    let rss = memoryUsage().rss
    if rss > peakRss.contents {
      peakRss := rss
    }
  }
  let timer = setInterval(watch, 20)

  let results = []
  for index in 0 to profiles->Array.length - 1 {
    let (name, cpuMs, wallMs) = await measure(profiles->Array.getUnsafe(index))
    watch()
    results->Array.push((name, cpuMs, wallMs))
  }
  clearInterval(timer)

  Console.log(
    `rows/batch ${rowsPerBatch->Int.toString}, ${measuredBatches->Int.toString} batches, median per batch`,
  )
  results->Array.forEach(((name, cpuMs, wallMs)) =>
    Console.log(
      `${name->String.padEnd(14, " ")} staging CPU ${cpuMs->Float.toFixed(
          ~digits=2,
        )} ms   wall ${wallMs->Float.toFixed(~digits=2)} ms`,
    )
  )
  Console.log(
    `peak RSS ${(peakRss.contents /. 1024. /. 1024.)->Float.toFixed(
        ~digits=1,
      )} MiB   GC pauses ${gcPauses()->Int.toString}`,
  )
}
