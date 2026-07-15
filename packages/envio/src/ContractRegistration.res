// The contract-registration loop. Decoupled from fetching: query responses drop
// their items straight into the buffer and queue the ones carrying a
// contractRegister handler, and this loop walks that queue in bounded batches,
// materialises each event's selected fields, runs its handler, and registers the
// dynamic contracts it produced. Processing is held behind the queue head until
// then, so a factory's children are always registered before anything at/after
// the registering block is processed. Re-enters fetch/process through the
// injected schedule* effects.

// Max registration events drained per chain in one round. Keeps a large factory
// backlog from materialising and running everything in a single tick.
let batchSize = 5000

let errorMessage = "Event contractRegister failed, please fix the error to keep the indexer running smoothly"

// Run the contractRegister handlers for an already-materialised batch of items
// and return the ones that registered at least one dynamic contract (with the
// dcs attached). Mirrors the previous inline fetch-time behaviour.
let runContractRegisters = async (~items: array<Internal.item>, ~config: Config.t): array<
  Internal.item,
> => {
  let itemsWithDcs = []

  let onRegister = (~item: Internal.item, ~contractAddress, ~contractName) => {
    let eventItem = item->Internal.castUnsafeEventItem
    let {blockNumber} = eventItem

    let dc: Internal.indexingAddress = {
      address: contractAddress,
      contractName,
      registrationBlock: blockNumber,
    }

    switch item->Internal.getItemDcs {
    | None => {
        item->Internal.setItemDcs([dc])
        itemsWithDcs->Array.push(item)
      }
    | Some(dcs) => dcs->Array.push(dc)
    }
  }

  let promises = []
  for idx in 0 to items->Array.length - 1 {
    let item = items->Array.getUnsafe(idx)
    let eventItem = item->Internal.castUnsafeEventItem
    let contractRegister = switch eventItem.onEventRegistration {
    | {contractRegister: Some(contractRegister)} => contractRegister
    | {contractRegister: None, eventConfig: {name: eventName}} =>
      // Unexpected case, since we should pass only events with contract register to this function
      JsError.throwWithMessage("Contract register is not set for event " ++ eventName)
    }

    // Catch sync and async errors
    try {
      let params: ContractRegisterContext.contractRegisterParams = {
        item,
        onRegister,
        config,
        isResolved: false,
      }
      let result = contractRegister(ContractRegisterContext.getContractRegisterArgs(params))

      // Even though `contractRegister` always returns a promise,
      // in the ReScript type, but it might return a non-promise value for TS API.
      if result->Utils.Promise.isCatchable {
        promises->Array.push(
          result
          ->Promise.thenResolve(r => {
            params.isResolved = true
            r
          })
          ->Promise.catch(exn => {
            params.isResolved = true
            exn->ErrorHandling.mkLogAndRaise(
              ~msg=errorMessage,
              ~logger=Ecosystem.getItemLogger(item, ~ecosystem=config.ecosystem),
            )
          }),
        )
      } else {
        params.isResolved = true
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg=errorMessage,
        ~logger=Ecosystem.getItemLogger(item, ~ecosystem=config.ecosystem),
      )
    }
  }

  if promises->Utils.Array.notEmpty {
    let _ = await Promise.all(promises)
  }

  itemsWithDcs
}

// Materialise a drained batch and run its handlers. Owns both awaits so its
// caller can route any failure to a single error boundary.
let drainChainBatch = async (cs: ChainState.t, ~items, ~config: Config.t) => {
  await cs->ChainState.materializeContractRegisterItems(~items, ~ecosystem=config.ecosystem.name)
  await runContractRegisters(~items, ~config)
}

// The single registration loop. Drains every chain's registration queue in
// bounded batches until nothing is pending, then re-kicks fetch and processing:
// registering dynamic contracts opens new ranges to fetch and lifts the
// processing barrier. `state.isRegistering` guarantees one instance. Producers
// (fetch responses, rollback completion, startup) re-kick it when new work lands.
let startRegistering = async (state: IndexerState.t, ~scheduleFetch, ~scheduleProcessing) =>
  if !(state->IndexerState.isRegistering) && !(state->IndexerState.isStopped) {
    state->IndexerState.beginRegistering
    let config = state->IndexerState.config

    let hasMoreWork = ref(true)
    while (
      hasMoreWork.contents &&
      !(state->IndexerState.isStopped) &&
      !(state->IndexerState.isResolvingReorg)
    ) {
      // Re-read the epoch each round: a rollback bumps it and trims the queues,
      // so a batch drained against the pre-rollback state must not be applied.
      let stateId = state->IndexerState.epoch
      let didWork = ref(false)

      let chainStates = state->IndexerState.chainStates->Dict.valuesToArray
      for i in 0 to chainStates->Array.length - 1 {
        let cs = chainStates->Array.getUnsafe(i)
        if (
          !(state->IndexerState.isStopped) &&
          !(state->IndexerState.isResolvingReorg) &&
          cs->ChainState.hasContractRegisterItems
        ) {
          let items = cs->ChainState.takeContractRegisterBatch(~maxSize=batchSize)
          switch await drainChainBatch(cs, ~items, ~config) {
          | exception exn =>
            IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=errorMessage))
          | itemsWithDcs =>
            if !(state->IndexerState.isStale(~stateId)) {
              cs->ChainState.applyContractRegisters(~registeredItems=items, ~itemsWithDcs)
              didWork := true
            }
          }
        }
      }

      if didWork.contents {
        // Registered contracts open new ranges to fetch and lift the processing
        // barrier, so re-kick both loops.
        scheduleFetch()
        scheduleProcessing()
      }

      // Keep looping while anything is still queued (a concurrent fetch may have
      // enqueued more while we awaited), not just while this round drained
      // something. This closes the lost-wakeup gap: the loop only exits with the
      // queues empty, and producers re-kick it when fresh items land afterwards.
      hasMoreWork :=
        state
        ->IndexerState.chainStates
        ->Dict.valuesToArray
        ->Array.some(cs => cs->ChainState.hasContractRegisterItems)
    }

    state->IndexerState.endRegistering
  }
