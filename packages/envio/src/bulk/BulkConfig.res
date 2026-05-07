// Bulk mode configuration — derived from env vars and the existing Config.t.
//
// The user enables bulk mode via ENVIO_BULK_MODE=1 and sets the few additional
// knobs that don't have a natural home in config.yaml (shard count, target
// table). Everything else (HyperSync URL, contract addresses, event signatures)
// is read from the regular config so the same project can be run in either
// mode.

type chainPlan = {
  chainId: int,
  hypersyncUrl: string,
  contractName: string,
  contractAddresses: array<string>,
  eventSignature: string,
  fromBlock: int,
  toBlock: int,
}

type t = {
  enabled: bool,
  shards: int,
  // Block range each work-queue chunk covers. Workers always process a chunk
  // end-to-end before pulling the next one from the queue, so this controls
  // the granularity of load balancing across workers. 50K is a sane default
  // for ERC20 Transfer on a chain like Ethereum mainnet.
  chunkSize: int,
  // ClickHouse table name to write into. v1 supports a single table.
  tableName: string,
  // ClickHouse connection details. Resolved at startup time so they propagate
  // to worker threads through workerData.
  clickhouseUrl: string,
  clickhouseDatabase: string,
  clickhouseUsername: string,
  clickhousePassword: string,
  // HyperSync API token for all workers.
  hypersyncToken: string,
  // Per-chain backfill plan.
  chains: array<chainPlan>,
}

let isEnabled = () => {
  switch %raw(`process.env.ENVIO_BULK_MODE`)->Nullable.toOption {
  | None | Some("") | Some("0") | Some("false") => false
  | _ => true
  }
}

let getEnvOrThrow = (key: string): string => {
  switch %raw(`process.env`)
  ->(Utils.magic: 'a => dict<string>)
  ->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(v) if v !== "" => v
  | _ => JsError.throwWithMessage(`Bulk mode requires env var ${key} to be set`)
  }
}

let getEnvOr = (key: string, ~fallback: string): string => {
  switch %raw(`process.env`)
  ->(Utils.magic: 'a => dict<string>)
  ->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(v) if v !== "" => v
  | _ => fallback
  }
}

let getEnvIntOr = (key: string, ~fallback: int): int => {
  switch %raw(`process.env`)
  ->(Utils.magic: 'a => dict<string>)
  ->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(v) if v !== "" =>
    switch Belt.Int.fromString(v) {
    | Some(n) => n
    | None => fallback
    }
  | _ => fallback
  }
}

let buildFromConfig = async (~config: Config.t): t => {
  if !isEnabled() {
    JsError.throwWithMessage("BulkConfig.buildFromConfig called but bulk mode is not enabled")
  }

  let shards = getEnvIntOr("ENVIO_BULK_SHARDS", ~fallback=8)
  let chunkSize = getEnvIntOr("ENVIO_BULK_CHUNK_SIZE", ~fallback=50_000)
  let tableName = getEnvOr("ENVIO_BULK_TABLE", ~fallback=BulkSchema.erc20Transfer.tableName)

  // ClickHouse connection — bulk mode always writes to ClickHouse.
  let clickhouseUrl = switch Env.ClickHouse.host() {
  | Some(h) => h
  | None => getEnvOrThrow("ENVIO_CLICKHOUSE_HOST")
  }
  let clickhouseDatabase = switch Env.ClickHouse.database() {
  | Some(d) => d
  | None => "envio_bulk"
  }
  let clickhouseUsername = switch Env.ClickHouse.username() {
  | Some(u) => u
  | None => getEnvOr("ENVIO_CLICKHOUSE_USERNAME", ~fallback="default")
  }
  let clickhousePassword = switch Env.ClickHouse.password() {
  | Some(p) => p
  | None => getEnvOr("ENVIO_CLICKHOUSE_PASSWORD", ~fallback="")
  }

  let hypersyncToken = switch Env.envioApiToken {
  | Some(t) => t
  | None => getEnvOrThrow("ENVIO_API_TOKEN")
  }

  // For every chain in the user's config, derive a backfill plan.
  let chains = []
  let chainConfigs = config.chainMap->ChainMap.values
  for idx in 0 to chainConfigs->Array.length - 1 {
    let chainConfig: Config.chain = chainConfigs->Array.getUnsafe(idx)

    let hypersyncUrl = switch chainConfig.sourceConfig {
    | EvmSourceConfig({hypersync: Some(url)}) => url
    | _ =>
      JsError.throwWithMessage(
        `Bulk mode requires HyperSync to be configured for chain ${chainConfig.id->Int.toString}`,
      )
    }

    // v1: pick the first contract that has a registered Transfer event. The
    // user is on the hook for not pointing this at a non-ERC20 contract — the
    // schema is hardcoded to the Transfer shape.
    if chainConfig.contracts->Array.length === 0 {
      JsError.throwWithMessage(
        `Chain ${chainConfig.id->Int.toString} has no contracts configured for bulk mode`,
      )
    }
    let contract: Config.contract = chainConfig.contracts->Array.getUnsafe(0)
    let addresses = contract.addresses->Array.map(Address.toString)

    if contract.eventSignatures->Array.length === 0 {
      JsError.throwWithMessage(`Contract ${contract.name} has no events configured for bulk mode`)
    }
    // v1: take the first event signature. Multi-event support is a follow-up
    // — we'd need one CH table per event shape and one decoder per signature.
    let eventSignature = contract.eventSignatures->Array.getUnsafe(0)

    let toBlock = switch chainConfig.endBlock {
    | Some(eb) => eb
    | None => getEnvIntOr("ENVIO_BULK_TO_BLOCK", ~fallback=0)
    }
    if toBlock === 0 {
      JsError.throwWithMessage(`Bulk mode requires an end block. Set chain.endBlock in config.yaml or ENVIO_BULK_TO_BLOCK env var.`)
    }

    chains
    ->Array.push({
      chainId: chainConfig.id,
      hypersyncUrl,
      contractName: contract.name,
      contractAddresses: addresses,
      eventSignature,
      fromBlock: chainConfig.startBlock,
      toBlock,
    })
    ->ignore
  }

  {
    enabled: true,
    shards,
    chunkSize,
    tableName,
    clickhouseUrl,
    clickhouseDatabase,
    clickhouseUsername,
    clickhousePassword,
    hypersyncToken,
    chains,
  }
}
