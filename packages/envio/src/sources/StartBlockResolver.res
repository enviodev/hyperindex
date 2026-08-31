// Resolves a chain's `start_block: latest` to a concrete block number, once,
// right before the indexer's first-ever persisted state is written (see
// `Persistence.init`). Never runs on a normal resume (crash recovery, a plain
// restarted process): `envio_chains.start_block` is written once and read
// back verbatim from then on (see `InternalTable.res`
// `Chains.initialFromConfig`/`metaFields`/`progressFields`), so a resolved
// "latest" naturally stays fixed across downtime instead of jumping to a new
// head - any gap gets backfilled rather than skipped. The CLI's `-r`
// (`--restart`) flag is the exception: it forces `reset=true` in
// `Persistence.init`, which wipes the DB and runs this resolver again, the
// same as any other fresh deploy.

// Sources built only to probe `getHeightOrThrow` - no real registrations
// exist yet at this point in startup (handler files load after persistence
// initializes), and none are needed just to ask a backend for its height.
let makeProbeSources = (chainConfig: Config.chain, ~lowercaseAddresses): array<Source.t> => {
  switch chainConfig.sourceConfig {
  | Config.SimulateSourceConfig(_) =>
    JsError.throwWithMessage(
      `Chain ${chainConfig.id->ChainId.toString}: resolving "latest" is not supported for a simulated source.`,
    )
  | _ =>
    let addressStore = AddressStore.make(
      ~ecosystem=chainConfig.ecosystem,
      ~shouldChecksum=!lowercaseAddresses,
      ~contracts=[],
    )
    ChainSources.make(~chainConfig, ~onEventRegistrations=[], ~addressStore, ~lowercaseAddresses)
  }
}

let resolveOneOrThrow = async (chainConfig: Config.chain, ~lowercaseAddresses): int => {
  switch chainConfig.startBlock {
  | Config.Number(n) => n
  | Config.Latest =>
    let sources = chainConfig->makeProbeSources(~lowercaseAddresses)
    let source = SourceManager.make(~sources, ~isRealtime=false)->SourceManager.getActiveSource
    let getHeightRetryInterval = SourceManager.makeGetHeightRetryInterval(
      ~initialRetryInterval=1000,
      ~backoffMultiplicative=2,
      ~maxRetryInterval=60_000,
    )
    let rec attempt = async retry =>
      switch await source.getHeightOrThrow() {
      | {height} => height
      | exception exn =>
        Logging.warn({
          "msg": `Failed to resolve the "latest" start block for chain ${chainConfig.id->ChainId.toString}. Retrying.`,
          "err": exn->Utils.prettifyExn,
        })
        await Utils.delay(getHeightRetryInterval(~retry))
        await attempt(retry + 1)
      }
    await attempt(0)
  }
}

// Resolves every chain's "latest" (if any) in parallel, and fails fast if a
// resolved start block would leave nothing to index.
let resolveAllOrThrow = async (chainConfigs: array<Config.chain>, ~lowercaseAddresses): array<
  Config.chain,
> =>
  await chainConfigs
  ->Array.map(async chainConfig => {
    let resolved = await chainConfig->resolveOneOrThrow(~lowercaseAddresses)
    switch chainConfig.endBlock {
    | Some(endBlock) if resolved > endBlock =>
      JsError.throwWithMessage(
        `Chain ${chainConfig.id->ChainId.toString}: the resolved "latest" start block (${resolved->Int.toString}) is greater than the configured end_block (${endBlock->Int.toString}). There is nothing to index - remove end_block, raise it above the chain's current head, or pin start_block to a fixed value instead of "latest".`,
      )
    | _ => ()
    }
    {...chainConfig, startBlock: Config.Number(resolved)}
  })
  ->Promise.all
