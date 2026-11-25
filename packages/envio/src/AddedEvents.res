// Indexes the events config.yaml gained into a storage that already holds the
// rest, under `envio start --backfill-added-events`.
//
// A chain that owes the added events their history gets a second run beside
// the one indexing it: from the chain's start block up to where the chain
// stood when the events were taken in, fetching those events alone. The chain
// itself carries on at the head with every event, the added ones included, so
// nothing waits on the catch-up. Three things hold the catch-up apart from the
// run beside it:
//
// - Its writes carry rows and how far it got, and nothing of the chain's own:
//   progress, frontier, checkpoints and metadata stay the head run's.
// - It never rolls back and keeps no history, so it has no checkpoint to put
//   out of block order among the chain's. In exchange it stays a reorg depth
//   behind the head, where nothing it writes can be undone.
// - A handler sees none of the order a full resync would give it: the added
//   events' history is indexed after, and alongside, everything else. That is
//   the operator's to vouch for, and why the flag is theirs to pass.

exception Failed

%%private(
  let isAdded = (registration: Internal.onEventRegistration, ~events: ResumePlan.addedEvents) =>
    switch events->Utils.Dict.dangerouslyGetNonOption(registration.eventConfig.contractName) {
    | Some(names) => names->Array.includes(registration.eventConfig.name)
    | None => false
    }
)

// The chain's registrations for the added events.
let registrationsOf = (
  debt: Persistence.addedEventsDebt,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
) =>
  registrationsByChainId
  ->Utils.Dict.dangerouslyGetNonOption(debt.chainId->ChainId.toString)
  ->Option.mapOr([], registrations => registrations.onEventRegistrations)
  ->Array.filter(registration => {
    let added = registration->isAdded(~events=debt.events)
    if added && registration.contractRegister->Option.isSome {
      JsError.throwWithMessage(
        `\`--backfill-added-events\` can't take ${registration.eventConfig.contractName}.${registration.eventConfig.name} on chain ${debt.chainId->ChainId.toString}: it has a contractRegister, and the addresses it registers would have events the indexer already went past. Remove the contractRegister and start again, or reset the indexer.`,
      )
    }
    added
  })

type chainCatchUp = {
  chainConfig: Config.chain,
  events: ResumePlan.addedEvents,
  initialChainState: Persistence.initialChainState,
}

// What the chain has to index for the events it owes, or `None` when that is
// nothing: it had not reached its start block, it has indexed them all, or it
// has no address the events could come from.
let chainCatchUpOf = (
  debt: Persistence.addedEventsDebt,
  ~untilBlock: int,
  ~chain: Persistence.initialChainState,
  ~config: Config.t,
  ~contractMapping: ContractMapping.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
) => {
  let chainConfig = config.chainMap->ChainMap.get(config->Config.getChain(~chainId=debt.chainId))
  let registrations = debt->registrationsOf(~registrationsByChainId)
  let contractNames = Utils.Set.fromArray(
    registrations->Array.map(registration => registration.eventConfig.contractName),
  )
  let hasSomethingToFetch =
    registrations->Array.some(registration => !registration.dependsOnAddresses) ||
      chain.addressRows.contractIds->Array.some(contractId =>
        contractNames->Utils.Set.has(contractMapping->ContractMapping.nameOfOrThrow(contractId))
      )
  let progressBlock = debt.progressBlock->Option.getOr(-1)
  if untilBlock < chain.startBlock || progressBlock >= untilBlock || !hasSomethingToFetch {
    None
  } else {
    Some({
      // The pre-threshold lag a chain that rolls back fetches under, which this
      // run would otherwise lose with the rollbacks it gives up.
      chainConfig: {
        ...chainConfig,
        blockLag: Pervasives.max(chainConfig.blockLag, chain.maxReorgDepth + 1),
      },
      events: debt.events,
      initialChainState: {
        ...chain,
        endBlock: Some(untilBlock),
        progressBlockNumber: progressBlock,
        progressBlockTime: None,
        // Not ready, so the run reads the sync sources rather than the realtime
        // ones a caught-up chain resumes on.
        timestampCaughtUpToHeadOrEndblock: None,
      },
    })
  }
}

// The chains this process drives that owe the added events their history, with
// where each one's catch-up ends pinned. Called before the chains are indexed
// any further: where a catch-up ends is where its chain stands now.
type t = {
  owingChainIds: array<ChainId.t>,
  chainCatchUps: array<chainCatchUp>,
  begun: Persistence.initialState,
}

let prepare = async (
  ~storage: Persistence.storage,
  ~config: Config.t,
  ~initialState: Persistence.initialState,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
) => {
  let chainIds = initialState.chains->Array.map(chain => chain.id)
  switch initialState.cleanRun ? [] : await storage.readAddedEvents(~chainIds) {
  | [] => None
  | owed =>
    // Before anything is pinned, so a registration the catch-up can't take
    // leaves the debt as it was found.
    owed->Array.forEach(debt => debt->registrationsOf(~registrationsByChainId)->ignore)
    let owingChainIds = owed->Array.map(debt => debt.chainId)
    await storage.beginAddedEvents(~chainIds=owingChainIds)
    let debts = await storage.readAddedEvents(~chainIds=owingChainIds)
    Some({
      owingChainIds,
      chainCatchUps: debts->Array.filterMap(debt =>
        switch (
          debt.untilBlock,
          initialState.chains->Array.find(chain => chain.id === debt.chainId),
        ) {
        | (Some(untilBlock), Some(chain)) =>
          debt->chainCatchUpOf(
            ~untilBlock,
            ~chain,
            ~config,
            ~contractMapping=initialState.contractMapping,
            ~registrationsByChainId,
          )
        | _ => None
        }
      ),
      begun: initialState,
    })
  }
}

type run = {
  // Resolves once the added events are in, and rejects with `Failed` after
  // `~onError` was told why.
  finished: promise<unit>,
  // Halts the catch-up and waits for what it had in flight, for a process
  // handing the storage over.
  stop: unit => promise<unit>,
}

// Starts the catch-up beside the run indexing the chains at the head.
let start = (
  {owingChainIds, chainCatchUps, begun}: t,
  ~storage: Persistence.storage,
  ~config: Config.t,
  ~logger: Logger.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
  ~onError: ErrorHandling.t => unit,
  ~sourceTiming=?,
  ~targetBufferSize=?,
): run => {
  let stateRef = ref(None)
  let settle = async () =>
    switch stateRef.contents {
    | Some(state) =>
      state->IndexerState.stop
      while state->IndexerState.isProcessing || state->IndexerState.writeFiber->Option.isSome {
        switch state->IndexerState.writeFiber {
        | Some(fiber) => await fiber
        | None => await Utils.delay(0)
        }
      }
    | None => ()
    }

  let runToEnd = async () => {
    let chains = chainCatchUps->Array.map(({chainConfig}) => (chainConfig.id, chainConfig))
    let untilBlocks = Dict.make()
    chainCatchUps->Array.forEach(({initialChainState}) =>
      untilBlocks->ChainId.Dict.set(initialChainState.id, initialChainState.endBlock)
    )
    logger->Logger.info(
      "Indexing the events config.yaml gained, up to where each chain stood. The chains carry on at the head meanwhile.",
      ~params={"untilBlock": untilBlocks},
    )
    try {
      await Promise.make((resolve, reject) => {
        let state = IndexerState.makeFromDbState(
          ~config={
            ...config,
            chainMap: chains->ChainMap.fromArrayUnsafe,
            defaultChain: chains->Array.get(0)->Option.map(((_, chainConfig)) => chainConfig),
            shouldRollbackOnReorg: false,
            isAddedEventsCatchUp: true,
          },
          ~logger=logger->Logger.withFields({"run": "added events"}),
          // The chains' metadata is the head run's to write.
          ~storage={...storage, setChainMeta: _ => Promise.resolve(%raw(`undefined`))},
          ~initialState={
            ...begun,
            chains: chainCatchUps->Array.map(({initialChainState}) => initialChainState),
            reorgCheckpoints: [],
          },
          ~registrationsByChainId,
          ~sourceTiming?,
          ~targetBufferSize?,
          ~finalizesIndexes=false,
          ~fetchesRegistration=(~chainId, registration) =>
            chainCatchUps->Array.some(({chainConfig, events}) =>
              chainConfig.id === chainId && registration->isAdded(~events)
            ),
          ~onError=errHandler => {
            onError(errHandler)
            reject(Failed)
          },
          ~onExit=() => resolve(),
        )
        stateRef := Some(state)
        state->IndexerLoop.start
      })
      await settle()
    } catch {
    | exn =>
      await settle()
      throw(exn)
    }
  }

  let isStopped = ref(false)
  {
    finished: (
      async () => {
        if chainCatchUps->Utils.Array.notEmpty {
          await runToEnd()
        }

        // A stopped catch-up has indexed only part of what is owed.
        if !isStopped.contents {
          await storage.finishAddedEvents(~chainIds=owingChainIds)
          logger->Logger.info("The added events are in.", ~params={"chainIds": owingChainIds})
        }
      }
    )(),
    stop: () => {
      isStopped := true
      settle()
    },
  }
}
