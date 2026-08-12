// Isolated storage-write benchmark: the same batch of entity changes written to
// Postgres-only entities and to ClickHouse-only entities, with no source
// fetching or handler execution in the way.
//
// The workload mirrors the erc20 template: per Transfer two Account sets, per
// Approval one Account set plus one Approval set, over a pool of addresses so
// ids repeat across a batch the way real token traffic makes them repeat.
//
// Needs a Postgres and a ClickHouse to write to, configured the same way the
// indexer reads them (ENVIO_PG_* / ENVIO_CLICKHOUSE_*).
//
// Run with: node bench/WriteBench.res.mjs [--events N] [--batches N] [--pool N]
//   [--history] [--pg-only] [--ch-only]

@val @scope("process") external argv: array<string> = "argv"
@val @scope("process") external exit: int => unit = "exit"
@val external globalGc: option<unit => unit> = "gc"

let arg = (name, ~default) =>
  switch argv->Array.indexOf(`--${name}`) {
  | -1 => default
  | i =>
    switch argv->Array.get(i + 1)->Option.flatMap(Int.fromString(_)) {
    | Some(v) => v
    | None => default
    }
  }

let flag = name => argv->Array.includes(`--${name}`)

let events = arg("events", ~default=20_000)
let batches = arg("batches", ~default=10)
let pool = arg("pool", ~default=30_000)
let approvalShare = arg("approval-share", ~default=12)
let history = flag("history")

let erc20Schema = `
type Account {
  id: ID!
  approvals: [Approval!]! @derivedFrom(field: "owner")
  balance: BigInt!
}

type Approval {
  id: ID!
  amount: BigInt!
  owner: Account!
  spender: Account!
}
`

let configYaml = (~clickhouse) => `
name: erc20-write-bench
disable_default_cross_chain: true
storage:
  postgres: true${clickhouse ? "\n  clickhouse:\n    default: true" : ""}
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 10861674
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
`

let parseConfig = (~clickhouse) => {
  let {config: configJson} = Core.fromUserApi(~schema=erc20Schema, configYaml(~clickhouse))
  let publicJson = configJson->JSON.parseOrThrow
  (Config.fromPublic(publicJson), publicJson->Config.stripSensitiveData)
}

// Deterministic Lehmer PRNG (MINSTD, modulus 2^31-1) so both backends get
// byte-identical input. Float arithmetic is exact here: the intermediate product
// stays under 2^53, which a 2^31 modulus would not.
let makeRandom = seed => {
  let state = ref(mod(seed, 2147483646)->Int.toFloat +. 1.)
  () => {
    let next = state.contents *. 48271.
    state := next -. Math.floor(next /. 2147483647.) *. 2147483647.
    state.contents->Float.toInt
  }
}

let addressOf = i => {
  let hex = i->Int.toString(~radix=16)
  "0x" ++ String.repeat("0", 40 - hex->String.length) ++ hex
}

type account = {id: string, balance: bigint}
type approval = {id: string, amount: bigint, owner_id: string, spender_id: string}

// One batch's worth of changes, in the shape Writing.res hands to storage.
let makeChanges = (~seed, ~firstCheckpointId: bigint) => {
  let random = makeRandom(seed)
  let accountChanges = []
  let approvalChanges = []
  let checkpointIds = []
  let checkpointBlockNumbers = []

  for i in 0 to events - 1 {
    let checkpointId = firstCheckpointId + i->BigInt.fromInt
    checkpointIds->Array.push(checkpointId)->ignore
    checkpointBlockNumbers->Array.push(10861674 + i / 20)->ignore

    let isApproval = mod(random(), 100) < approvalShare
    let a = addressOf(mod(random(), pool))
    let b = addressOf(mod(random(), pool))
    let value = (mod(random(), 1_000_000) + 1)->BigInt.fromInt * 1000000000000n

    if isApproval {
      accountChanges
      ->Array.push(
        Change.Set({
          entityId: a->EntityId.unsafeOfString,
          checkpointId,
          entity: {id: a, balance: 0n}->(Utils.magic: account => Internal.entity),
        }),
      )
      ->ignore
      let approvalId = a ++ "-" ++ b
      approvalChanges
      ->Array.push(
        Change.Set({
          entityId: approvalId->EntityId.unsafeOfString,
          checkpointId,
          entity: {
            id: approvalId,
            amount: value,
            owner_id: a,
            spender_id: b,
          }->(Utils.magic: approval => Internal.entity),
        }),
      )
      ->ignore
    } else {
      accountChanges
      ->Array.push(
        Change.Set({
          entityId: a->EntityId.unsafeOfString,
          checkpointId,
          entity: {id: a, balance: -value}->(Utils.magic: account => Internal.entity),
        }),
      )
      ->ignore
      accountChanges
      ->Array.push(
        Change.Set({
          entityId: b->EntityId.unsafeOfString,
          checkpointId,
          entity: {id: b, balance: value}->(Utils.magic: account => Internal.entity),
        }),
      )
      ->ignore
    }
  }

  // The in-memory store keys a change by (id, checkpoint), so a self-transfer
  // — the same address on both sides of one event — yields one change, not two.
  // Postgres enforces that with a primary key on the history table, so the
  // generator has to collapse them the same way.
  let dedupByIdAndCheckpoint = changes => {
    let latest = Dict.make()
    let order = []
    changes->Array.forEach(change => {
      let key = `${change->Change.getEntityId->EntityId.toKey}|${change
        ->Change.getCheckpointId
        ->BigInt.toString}`
      if latest->Utils.Dict.dangerouslyGetNonOption(key)->Option.isNone {
        order->Array.push(key)->ignore
      }
      latest->Dict.set(key, change)
    })
    order->Array.map(key => latest->Dict.getUnsafe(key))
  }

  (
    accountChanges->dedupByIdAndCheckpoint,
    approvalChanges->dedupByIdAndCheckpoint,
    checkpointIds,
    checkpointBlockNumbers,
  )
}

let makeBatch = (~checkpointIds, ~checkpointBlockNumbers): Batch.t => {
  let count = checkpointIds->Array.length
  {
    totalBatchSize: count,
    items: [],
    progressedChainsById: Dict.make(),
    isInReorgThreshold: history,
    checkpointIds,
    checkpointChainIds: checkpointIds->Array.map(_ => 1->ChainId.fromInt),
    checkpointBlockNumbers,
    checkpointBlockHashes: checkpointIds->Array.map(_ => Null.null),
    checkpointEventsProcessed: checkpointIds->Array.map(_ => 1),
  }
}

let uniqueIds = (changes: array<Change.t<Internal.entity>>) => {
  let set = Utils.Set.make()
  changes->Array.forEach(change =>
    set->Utils.Set.add(change->Change.getEntityId->EntityId.toKey)->ignore
  )
  set->Utils.Set.size
}

let run = async (~clickhouse) => {
  let (config, envioInfo) = parseConfig(~clickhouse)
  let pgSchema = clickhouse ? "write_bench_ch" : "write_bench_pg"
  let chDatabase = "write_bench_ch"
  let env = %raw(`process.env`)
  env->Dict.set("ENVIO_CLICKHOUSE_DATABASE", chDatabase)
  env->Dict.set("ENVIO_PG_SCHEMA", pgSchema)

  let sql = PgStorage.makeClient()
  let persistence = PgStorage.makePersistenceFromConfig(
    ~config,
    ~storage=PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false),
  )
  await persistence->Persistence.init(
    ~reset=true,
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~envioInfo,
    ~resetCommand="",
    ~runCommand=None,
  )
  let storage = persistence.storage

  let accountConfig = config.userEntitiesByName->Dict.getUnsafe("Account")
  let approvalConfig = config.userEntitiesByName->Dict.getUnsafe("Approval")

  // Generate every batch up front so generation never lands inside a timing window.
  let prepared = []
  let nextCheckpointId = ref(1n)
  for b in 0 to batches - 1 {
    let (accountChanges, approvalChanges, checkpointIds, checkpointBlockNumbers) = makeChanges(
      ~seed=1000 + b,
      ~firstCheckpointId=nextCheckpointId.contents,
    )
    nextCheckpointId := nextCheckpointId.contents + events->BigInt.fromInt
    prepared
    ->Array.push((
      makeBatch(~checkpointIds, ~checkpointBlockNumbers),
      (
        [
          ({entityConfig: accountConfig, scope: Internal.Chain(1->ChainId.fromInt), changes: accountChanges}: Persistence.updatedEntity),
          {entityConfig: approvalConfig, scope: Chain(1->ChainId.fromInt), changes: approvalChanges},
        ]: array<Persistence.updatedEntity>
      ),
      accountChanges->Array.length + approvalChanges->Array.length,
      uniqueIds(accountChanges) + uniqueIds(approvalChanges),
    ))
    ->ignore
  }

  let perBackendSeconds = Dict.make()
  let onWrite = (~storage as name, ~timeSeconds) =>
    perBackendSeconds->Dict.set(
      name,
      perBackendSeconds->Dict.get(name)->Option.getOr(0.) +. timeSeconds,
    )

  switch globalGc {
  | Some(gc) => gc()
  | None => ()
  }

  let totalChanges = ref(0)
  let totalUnique = ref(0)
  let started = Performance.now()
  for i in 0 to prepared->Array.length - 1 {
    let (batch, updatedEntities, changesCount, uniqueCount) = prepared->Array.getUnsafe(i)
    totalChanges := totalChanges.contents + changesCount
    totalUnique := totalUnique.contents + uniqueCount
    try {
      await storage.writeBatch(
        ~batch,
        ~rollback=None,
        ~isInReorgThreshold=history,
        ~config,
        ~allEntities=persistence.allEntities,
        ~updatedEffectsCache=[],
        ~updatedEntities,
        ~chainMetaData=None,
        ~onWrite,
      )
    } catch {
    | exn =>
      Console.log(exn->Utils.prettifyExn)
      exit(1)
    }
  }
  let wallSeconds = started->Performance.secondsSince
  await storage.close()

  Console.log(
    `${clickhouse ? "clickhouse-only" : "postgres-only"} | wall ${wallSeconds->Float.toFixed(
        ~digits=2,
      )}s | changes ${totalChanges.contents->Int.toString} | rowsWritten ${(clickhouse
        ? totalChanges.contents + events * batches
        : totalUnique.contents)->Int.toString} | ${perBackendSeconds
      ->Dict.toArray
      ->Array.map(((k, v)) => `${k} ${v->Float.toFixed(~digits=2)}s`)
      ->Array.joinUnsafe(" | ")}`,
  )
  Console.log(
    `  -> ${(totalChanges.contents->Int.toFloat /. wallSeconds)
      ->Float.toFixed(
        ~digits=0,
      )} changes/s, ${((clickhouse ? totalChanges.contents + events * batches : totalUnique.contents)
        ->Int.toFloat /. wallSeconds)->Float.toFixed(~digits=0)} rows/s, ${(wallSeconds *. 1000. /.
      prepared->Array.length->Int.toFloat)->Float.toFixed(~digits=0)} ms/batch`,
  )
}

let main = async () => {
  Console.log(
    `WriteBench: events/batch=${events->Int.toString} batches=${batches->Int.toString} addressPool=${pool->Int.toString} history=${history
        ? "on"
        : "off"}`,
  )
  if !flag("ch-only") {
    await run(~clickhouse=false)
  }
  if !flag("pg-only") {
    await run(~clickhouse=true)
  }
  exit(0)
}

main()->Promise.ignore
