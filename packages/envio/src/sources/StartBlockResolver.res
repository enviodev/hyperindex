// Resolves a chain's `start_block: latest` to a concrete block number, once,
// right before the indexer's first-ever persisted state is written (see
// `Persistence.init`). Never runs on a normal resume (crash recovery, a plain
// restarted process): `envio_chains.start_block` is written once and read
// back verbatim from then on, so a resolved "latest" naturally stays fixed
// across downtime instead of jumping to a new head - any gap gets backfilled
// rather than skipped. The CLI's `-r` (`--restart`) flag is the exception: it
// forces `reset=true` in `Persistence.init`, which wipes the DB and runs this
// again, the same as any other fresh deploy.

// Sources built only to read the chain's height. No registrations exist yet at
// this point in startup - handler files load after persistence initializes -
// and none are needed to ask a backend how far it has got. These are not the
// sources the chain goes on to index with; those are built later, once
// registrations exist.
let makeProbeSources = (chainConfig: Config.chain, ~lowercaseAddresses): array<Source.t> => {
  let addressStore = AddressStore.make(
    ~ecosystem=chainConfig.ecosystem,
    ~shouldChecksum=!lowercaseAddresses,
    ~contracts=[],
  )
  ChainSources.make(~chainConfig, ~onEventRegistrations=[], ~addressStore, ~lowercaseAddresses)
}

// Waiting for a height above 0 is the same question as "what is the head", and
// it comes with the runtime's own answer to a source that won't say: retry with
// backoff, a bound on how long any one request is waited for, and failover to
// `for: fallback` sources once the primary has been quiet for a stall window.
//
// It never gives up, which is what makes it safe to use here. A deadline would
// need a race, and the losing side of that race is a registered waiter and a
// live poll loop that nothing can reach to stop.
let resolveHeadOrThrow = async (
  chainConfig: Config.chain,
  ~lowercaseAddresses,
  ~getHeightRetryInterval=?,
  ~newBlockStallTimeout=?,
): int => {
  let sourceManager = SourceManager.make(
    ~sources=chainConfig->makeProbeSources(~lowercaseAddresses),
    ~isRealtime=false,
    ~getHeightRetryInterval?,
    ~newBlockStallTimeout?,
  )
  await sourceManager->SourceManager.waitForNewBlock(
    ~knownHeight=0,
    ~isRealtime=false,
    ~reducedPolling=false,
  )
}

// Sequential rather than `Promise.all`: a chain that fails validation must not
// leave sibling chains' height polling running behind the rejection.
let resolveAllOrThrow = async (
  chainConfigs: array<Config.chain>,
  ~lowercaseAddresses,
  ~getHeightRetryInterval=?,
  ~newBlockStallTimeout=?,
): array<Config.chain> => {
  let resolved = []
  for i in 0 to chainConfigs->Array.length - 1 {
    let chainConfig = chainConfigs->Array.getUnsafe(i)
    let chainConfig = switch chainConfig.startBlock {
    | Config.Block(_) => chainConfig
    | Config.Latest =>
      let head = await chainConfig->resolveHeadOrThrow(
        ~lowercaseAddresses,
        ~getHeightRetryInterval?,
        ~newBlockStallTimeout?,
      )
      let chainId = chainConfig.id->ChainId.toString
      switch chainConfig.endBlock {
      | Some(endBlock) if head > endBlock =>
        JsError.throwWithMessage(
          `Chain ${chainId}: the "latest" start block resolved to ${head->Int.toString}, which is past the configured end_block (${endBlock->Int.toString}). There is nothing to index - remove end_block, raise it above the chain's current head, or pin start_block to a fixed value instead of "latest".`,
        )
      | _ => ()
      }
      // Checked here, before anything is persisted: the same guard in
      // `ChainState.makeInternal` would only fire after the resolved head is
      // written to envio_chains, and then again on every resume.
      chainConfig.contracts->Array.forEach(contract =>
        switch contract.startBlock {
        | Some(contractStartBlock) if contractStartBlock < head =>
          JsError.throwWithMessage(
            `Chain ${chainId}: contract "${contract.name}" has start_block ${contractStartBlock->Int.toString}, but the chain's "latest" start block resolved to ${head->Int.toString}. A contract can't start before its chain does - remove the contract's start_block, or pin the chain's start_block to a fixed value instead of "latest".`,
          )
        | _ => ()
        }
      )
      Logging.info({
        "msg": `Resolved the "latest" start block for chain ${chainId} to block ${head->Int.toString}.`,
        "chainId": chainConfig.id,
        "startBlock": head,
      })
      {...chainConfig, startBlock: Config.Block(head)}
    }
    resolved->Array.push(chainConfig)->ignore
  }
  resolved
}
