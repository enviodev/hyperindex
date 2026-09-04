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

// Long enough for `SourceManager.waitForNewBlock` to fail over to `for:
// fallback` sources (after its stall timeout) before startup gives up.
let defaultDeadlineMs = 5 * 60 * 1000

// Sources built only to probe the chain's height - no real registrations exist
// yet at this point in startup (handler files load after persistence
// initializes), and none are needed just to ask a backend for its height.
let makeProbeSources = (chainConfig: Config.chain, ~lowercaseAddresses): array<Source.t> => {
  let addressStore = AddressStore.make(
    ~ecosystem=chainConfig.ecosystem,
    ~shouldChecksum=!lowercaseAddresses,
    ~contracts=[],
  )
  ChainSources.make(~chainConfig, ~onEventRegistrations=[], ~addressStore, ~lowercaseAddresses)
}

let resolveHeadOrThrow = async (
  chainConfig: Config.chain,
  ~lowercaseAddresses,
  ~getHeightRetryInterval=?,
  ~newBlockStallTimeout=?,
  ~deadlineMs,
): int => {
  // The runtime's own height polling: retries a failing source with backoff
  // and fails over to `for: fallback` sources after the stall timeout, rather
  // than pinning startup on a single primary.
  let sourceManager = SourceManager.make(
    ~sources=chainConfig->makeProbeSources(~lowercaseAddresses),
    ~isRealtime=false,
    ~getHeightRetryInterval?,
    ~newBlockStallTimeout?,
  )
  // The probe polls and never subscribes (`~isRealtime=false`), so nothing here
  // opens a height stream: a one-shot head fetch has nothing to gain from one,
  // and `HeightFeed.enableStream` has no per-wait counterpart that would take it
  // back off afterwards.
  let timeoutId = ref(None)
  let deadline = Promise.make((_, reject) => {
    timeoutId := Some(setTimeout(() => {
          reject(
            JsError.make(
              `Chain ${chainConfig.id->ChainId.toString}: couldn't resolve the "latest" start block - no source answered a height request within ${(deadlineMs / 1000)
                  ->Int.toString}s. Check the chain's RPC/HyperSync endpoints and ENVIO_API_TOKEN, then start again.`,
            ),
          )
        }, deadlineMs))
  })
  let clearDeadline = () =>
    switch timeoutId.contents {
    | Some(id) => clearTimeout(id)
    | None => ()
    }
  // `waitForNewBlock` never settles when the deadline wins the race, so its own
  // cleanup never runs. Disposing is what ends the poll loops it left behind -
  // otherwise a startup that already gave up keeps asking the endpoint for a
  // height for the life of the process.
  switch await Promise.race([
    sourceManager->SourceManager.waitForNewBlock(
      ~knownHeight=0,
      ~isRealtime=false,
      ~reducedPolling=false,
    ),
    deadline,
  ]) {
  | height =>
    clearDeadline()
    sourceManager->SourceManager.dispose
    height
  | exception exn =>
    clearDeadline()
    sourceManager->SourceManager.dispose
    throw(exn)
  }
}

// Sequential rather than `Promise.all`: a chain that fails validation must not
// leave sibling chains' height polling running behind the rejection.
let resolveAllOrThrow = async (
  chainConfigs: array<Config.chain>,
  ~lowercaseAddresses,
  ~getHeightRetryInterval=?,
  ~newBlockStallTimeout=?,
  ~deadlineMs=defaultDeadlineMs,
): array<Config.chain> => {
  let resolved = []
  for i in 0 to chainConfigs->Array.length - 1 {
    let chainConfig = chainConfigs->Array.getUnsafe(i)
    let chainConfig = if chainConfig.isLatestStartBlock {
      let head = await chainConfig->resolveHeadOrThrow(
        ~lowercaseAddresses,
        ~getHeightRetryInterval?,
        ~newBlockStallTimeout?,
        ~deadlineMs,
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
      {...chainConfig, startBlock: head}
    } else {
      chainConfig
    }
    resolved->Array.push(chainConfig)->ignore
  }
  resolved
}
