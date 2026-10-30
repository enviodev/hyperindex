// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chainId: ChainId.t,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let hasContractRegister = (item: Internal.item) =>
  switch item {
  | Event({onEventRegistration: {contractRegister: Some(_)}}) => true
  | Block({onBlockRegistration: {contractRegister: ?Some(_)}}) => true
  | Event(_) | Block(_) => false
  }

let invokeContractRegister = (runtime: HandlerRuntime.t, item: Internal.item) =>
  switch item {
  | Event({onEventRegistration}) =>
    let contractRegister = switch onEventRegistration {
    | {contractRegister: Some(contractRegister)} => contractRegister
    | {contractRegister: None, eventConfig: {name: eventName}} =>
      // Unexpected case, since we should pass only events with contract register to this function
      JsError.throwWithMessage("Contract register is not set for event " ++ eventName)
    }
    contractRegister({
      event: item->Ecosystem.getItemEvent(~ecosystem=runtime->HandlerRuntime.ecosystem),
      context: runtime.contractRegisterContext,
    })
  | Block({blockNumber, onBlockRegistration, ?block}) =>
    let contractRegister = switch onBlockRegistration {
    | {contractRegister: ?Some(contractRegister)} => contractRegister
    | {name} => JsError.throwWithMessage("Contract register is not set for block handler " ++ name)
    }
    let ecosystem = runtime->HandlerRuntime.ecosystem
    let context = runtime.contractRegisterContext
    // A block handler's register pass gets what its handler gets, the block (or
    // slot), with the register context in place of the handler's.
    contractRegister(
      switch ecosystem.name {
      | Svm => {slot: blockNumber, ?block, context}
      | Evm | Fuel => {
          block: block->Option.getOr(Ecosystem.makeKeyOnlyBlock(~blockNumber, ~ecosystem)),
          context,
        }
      },
    )
  }

let runContractRegistersOrThrow = async (
  ~itemsWithContractRegister: array<Internal.item>,
  ~runtime: HandlerRuntime.t,
  ~chainState: ChainState.t,
) => {
  // contractRegister handlers can read event.transaction and event.block, so
  // materialise the selected fields onto the payloads before running them. All
  // items belong to the chain being fetched, and both stores are the chain's
  // own, which this response's pages have already been merged into.
  // A subgraph's block register passes ride along; their blocks have no page.
  await ChainState.materializePageItems(
    ~items=Env.subgraphMode.contents
      ? itemsWithContractRegister->Array.filter(item => item->Internal.getItemKind === 0)
      : itemsWithContractRegister,
    ~transactionStore=chainState->ChainState.transactionStore,
    ~blockStore=chainState->ChainState.blockStore,
    ~shouldChecksum=chainState->ChainState.shouldChecksum,
  )

  // Every run of the response adds into the same registrations, in call order.
  let registrations: array<AddressStore.registration> = []
  let chainLogger = chainState->ChainState.logger
  let ecosystem = runtime->HandlerRuntime.ecosystem
  let isSubgraph = Env.subgraphMode.contents

  let _ = await itemsWithContractRegister
  ->Array.map(async item => {
    let run: RunScope.contractRegisterRun = {
      item,
      isResolved: false,
      chainLogger,
      ecosystem,
      registrations,
      creationRound: ?(
        isSubgraph
          ? Some(
              switch item {
              // A block handler is one of its block's own triggers.
              | Block(_) => 1
              | Event(_) =>
                chainState->ChainState.fetchState->FetchState.creationRoundOfRegistration(~item)
              },
            )
          : None
      ),
    }
    let scope = RunScope.ContractRegister(run)
    switch await RunScope.enter(scope, invokeContractRegister, runtime, item) {
    | exception exn =>
      scope->RunScope.resolve
      exn->ErrorHandling.mkLogAndRaise(
        ~msg=switch item {
        | Event(
            _,
          ) => "Event contractRegister failed, please fix the error to keep the indexer running smoothly"
        | Block(
            _,
          ) => "Block handler contractRegister failed, please fix the error to keep the indexer running smoothly"
        },
        ~logger=run->RunScope.contractRegisterLogger,
      )
    | () => scope->RunScope.resolve
    }
  })
  ->Promise.all

  registrations
}

// A response's events and the block passes of the same blocks, in the order
// graph-node runs their triggers: a `once` handler first in its block, the
// other block handlers after the block's logs and calls
// (chain/ethereum/src/trigger.rs, `impl Ord for EthereumTrigger`).
let mergeRegisterItems = (~eventItems: array<Internal.item>, ~blockItems: array<Internal.item>) => {
  let merged = []
  let i = ref(0)
  let j = ref(0)
  while i.contents < eventItems->Array.length || j.contents < blockItems->Array.length {
    let takeBlock = switch (eventItems->Array.get(i.contents), blockItems->Array.get(j.contents)) {
    | (None, _) => true
    | (_, None) => false
    | (Some(event), Some(block)) =>
      let eventBlock = event->Internal.getItemBlockNumber
      let blockBlock = block->Internal.getItemBlockNumber
      blockBlock < eventBlock || (blockBlock === eventBlock && block->Internal.itemRunsFirst)
    }
    if takeBlock {
      merged->Array.push(blockItems->Array.getUnsafe(j.contents))
      j := j.contents + 1
    } else {
      merged->Array.push(eventItems->Array.getUnsafe(i.contents))
      i := i.contents + 1
    }
  }
  merged
}

// An unfiltered handler has a pass for every block, so a run with block passes
// starts them a chunk at a time, in chain order: each chunk reads what the ones
// before it saved, and a pass is started before any later one of its chunk,
// which is the order the runtime hands out its slots in.
let blockRegisterChunk = 2048
// Block passes built at once: a response can span millions of blocks.
let blockRegisterWindow = 10_000
let maxResponseBlockPasses = 50_000

let runRegisterPassesOrThrow = async (
  ~eventItems: array<Internal.item>,
  ~blockItems: array<Internal.item>,
  ~runtime: HandlerRuntime.t,
  ~chainState: ChainState.t,
) => {
  let items = mergeRegisterItems(~eventItems, ~blockItems)
  let registrations = []
  let start = ref(0)
  while start.contents < items->Array.length {
    let chunk = items->Array.slice(~start=start.contents, ~end=start.contents + blockRegisterChunk)
    registrations
    ->Array.pushMany(
      await runContractRegistersOrThrow(~itemsWithContractRegister=chunk, ~runtime, ~chainState),
    )
    ->ignore
    start := start.contents + blockRegisterChunk
  }
  registrations
}

// Passes of a chunk finish in any order, and of two registrations of one
// address the store keeps the first: it has to be the earlier block's.
let sortRegistrations = (registrations: array<AddressStore.registration>) =>
  registrations->Array.toSorted((a, b) =>
    switch Int.compare(a.registrationBlock, b.registrationBlock) {
    | 0. => Int.compare(a.creationRound->Option.getOr(1), b.creationRound->Option.getOr(1))
    | order => order
    }
  )

// A response's event passes with the block passes of the blocks after the last
// one passed, through `through`, a window of block passes at a time. Returns
// the registrations and the last block passed, if the block passes advanced.
let runResponsePassesOrThrow = async (
  ~eventItems: array<Internal.item>,
  ~through,
  ~runtime: HandlerRuntime.t,
  ~chainState: ChainState.t,
) => {
  let registrations = []
  let eventIdx = ref(0)
  let passedThrough = ref(None)
  let after = ref(chainState->ChainState.blockRegisterThrough->Option.getOr(through))
  let isDone = ref(false)
  while !isDone.contents {
    let (blockItems, covered) = switch chainState->ChainState.blockRegisterItemsAfter(
      ~after=after.contents,
      ~through,
      ~limit=blockRegisterWindow,
    ) {
    | Some((blockItems, covered)) => (blockItems, Some(covered))
    | None => ([], None)
    }
    // The events up to the window's last block go with it, and the last
    // window takes the rest.
    let eventEnd = switch covered {
    | Some(covered) if covered < through =>
      let idx = ref(eventIdx.contents)
      while (
        idx.contents < eventItems->Array.length &&
          eventItems->Array.getUnsafe(idx.contents)->Internal.getItemBlockNumber <= covered
      ) {
        idx := idx.contents + 1
      }
      idx.contents
    | _ => eventItems->Array.length
    }
    let startedAt = Date.now()
    let windowRegistrations = await runRegisterPassesOrThrow(
      ~eventItems=eventItems->Array.slice(~start=eventIdx.contents, ~end=eventEnd),
      ~blockItems,
      ~runtime,
      ~chainState,
    )
    chainState
    ->ChainState.logger
    ->Logger.trace(
      "Ran register passes with block passes",
      ~params={
        "after": after.contents,
        "through": covered,
        "blockPasses": blockItems->Array.length,
        "eventPasses": eventEnd - eventIdx.contents,
        "registrations": windowRegistrations->Array.length,
        "ms": Date.now() -. startedAt,
      },
    )
    registrations->Array.pushMany(windowRegistrations)->ignore
    eventIdx := eventEnd
    switch covered {
    | Some(covered) =>
      passedThrough := Some(covered)
      after := covered
      isDone := covered >= through && eventIdx.contents >= eventItems->Array.length
    | None => isDone := true
    }
  }
  (registrations->sortRegistrations, passedThrough.contents)
}

// A subgraph's register pass for one event can cost a dozen contract calls, and
// a response is applied only when every pass of it is done: a 5,000-event
// response of PairCreated made PancakeSwap v2 wait for ~15,000 calls before it
// committed anything. A response with more register passes than the calls can
// answer promptly is cut after a block and the rest fetched again; HyperSync
// answers that far faster than the RPC does. The runtime reports the calls its
// finished passes made (`__envioSubgraphRegisterCostPerItem`); until it has
// seen enough passes the cost is assumed to be high, and a run whose passes
// make no calls is never cut.
let registerCallsPerItem: unit => option<float> = %raw(`() => {
  const cost = globalThis.__envioSubgraphRegisterCostPerItem
  const value = cost ? cost() : undefined
  return value === undefined ? undefined : value
}`)

// A subgraph's register store keeps an entity's past versions for the passes
// still to read them, and none starts below the lowest partition frontier.
let reportRegisterFrontier: (int, int) => unit = %raw(`(chainId, block) => {
  const report = globalThis.__envioSubgraphRegisterFrontier
  if (report) report(chainId, block)
}`)

let registerCallsPerChunk = 3000.
let unknownCostChunk = 100
let minRegisterChunk = 100

let registerChunkLimit = () =>
  if !Env.subgraphMode.contents {
    None
  } else {
    switch Env.subgraphRegisterChunk {
    | Some(limit) => limit > 0 ? Some(limit) : None
    | None =>
      switch registerCallsPerItem() {
      | None => Some(unknownCostChunk)
      | Some(cost) if cost < 0.5 => None
      | Some(cost) =>
        Some(Pervasives.max(minRegisterChunk, (registerCallsPerChunk /. cost)->Float.toInt))
      }
    }
  }

// The items and last block of `response` up to the block holding the `limit`th
// item that has a register pass. Whole blocks only: a block's items are never
// split between two responses.
let cutAtRegisterLimit = (items: array<Internal.item>, ~latestFetchedBlock, ~limit) => {
  let seen = ref(0)
  let cutIdx = ref(-1)
  let idx = ref(0)
  while cutIdx.contents < 0 && idx.contents < items->Array.length {
    if items->Array.getUnsafe(idx.contents)->hasContractRegister {
      seen := seen.contents + 1
      if seen.contents >= limit {
        cutIdx := idx.contents
      }
    }
    idx := idx.contents + 1
  }
  if cutIdx.contents < 0 {
    (items, latestFetchedBlock)
  } else {
    let cutBlock = items->Array.getUnsafe(cutIdx.contents)->Internal.getItemBlockNumber
    let last = ref(cutIdx.contents)
    while (
      last.contents + 1 < items->Array.length &&
        items->Array.getUnsafe(last.contents + 1)->Internal.getItemBlockNumber <= cutBlock
    ) {
      last := last.contents + 1
    }
    if last.contents + 1 >= items->Array.length && cutBlock >= latestFetchedBlock {
      (items, latestFetchedBlock)
    } else {
      (items->Array.slice(~start=0, ~end=last.contents + 1), cutBlock)
    }
  }
}

let rec onQueryResponse = async (
  state: IndexerState.t,
  {chainId, response, query}: partitionQueryResponse,
  ~runtime,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let chainState = state->IndexerState.getChainState(~chainId)
    let {
      parsedQueueItems,
      transactionStore,
      blockStore,
      latestFetchedBlockNumber,
      stats,
      knownHeight,
    } = response
    let (parsedQueueItems, latestFetchedBlockNumber) = switch registerChunkLimit() {
    | Some(limit) =>
      parsedQueueItems->cutAtRegisterLimit(~latestFetchedBlock=latestFetchedBlockNumber, ~limit)
    | None => (parsedQueueItems, latestFetchedBlockNumber)
    }

    chainState->ChainState.recordBlockRangeFetch(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Option.getOr(0.),
      ~numEvents=parsedQueueItems->Array.length,
      ~blockRangeSize=latestFetchedBlockNumber - query.fromBlock + 1,
    )

    let numContractRegisterEvents =
      parsedQueueItems->Array.reduce(0, (count, item) =>
        item->hasContractRegister ? count + 1 : count
      )
    if numContractRegisterEvents === 0 {
      chainState
      ->ChainState.logger
      ->Logger.trace(
        "Finished querying",
        ~params={
          "partitionId": query.partitionId,
          "fromBlock": query.fromBlock,
          "toBlock": latestFetchedBlockNumber,
          "numEvents": parsedQueueItems->Array.length,
        },
      )
    } else {
      chainState
      ->ChainState.logger
      ->Logger.trace(
        "Finished querying",
        ~params={
          "partitionId": query.partitionId,
          "fromBlock": query.fromBlock,
          "toBlock": latestFetchedBlockNumber,
          "numEvents": parsedQueueItems->Array.length,
          "numContractRegisterEvents": numContractRegisterEvents,
        },
      )
    }

    let reorgResult = chainState->ChainState.registerReorgGuard(~blockStore, ~knownHeight)

    let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
    | ReorgDetected({scannedBlock, receivedBlock}) => {
        chainState
        ->ChainState.logger
        ->Logger.info(
          `Blockchain reorg detected. ${chainState->ChainState.shouldRollbackOnReorg
              ? "Initiating indexer rollback"
              : "NOT initiating indexer rollback due to configuration"}.`,
          ~params={
            "blockNumber": scannedBlock.blockNumber,
            "indexedBlockHash": scannedBlock.blockHash,
            "receivedBlockHash": receivedBlock.blockHash,
          },
        )
        chainState->ChainState.recordReorgDetected(~blockNumber=scannedBlock.blockNumber)

        // Must agree with the `reportOnly` flag registerReorgGuard passed to
        // the merge: a discarded page (rollback mode) needs the rollback to
        // actually happen, or the stale stored hash re-reports forever.
        if chainState->ChainState.shouldRollbackOnReorg {
          Some(scannedBlock.blockNumber)
        } else {
          None
        }
      }
    | NoReorg => None
    }

    switch rollbackWithReorgDetectedBlockNumber {
    | Some(reorgDetectedBlockNumber) =>
      // Prepare every chain for the rollback: restore each events-processed
      // counter (the previous, uncommitted rollback subtracted from all chains,
      // so undo that before the new rollback subtracts again) and drop pending
      // queries requested against the about-to-be-invalidated chain state.
      let eventsProcessedDiffByChain = switch state->IndexerState.rollbackState {
      | RollbackReady({eventsProcessedDiffByChain}) => Some(eventsProcessedDiffByChain)
      | _ => None
      }
      state
      ->IndexerState.chainStates
      ->Utils.Dict.forEach(cs =>
        cs->ChainState.prepareReorg(
          ~eventsProcessedDiff=switch eventsProcessedDiffByChain {
          | Some(byChain) =>
            byChain->ChainId.Dict.dangerouslyGetNonOption((cs->ChainState.chainConfig).id)
          | None => None
          },
        )
      )
      state->IndexerState.beginReorg(~chainId, ~blockNumber=reorgDetectedBlockNumber)
      // Advances synchronously to FindingReorgDepth, so a concurrent rollback
      // kick (eg from the processing loop quiescing) collapses into this one.
      scheduleRollback()
    // No rollback: either the guard found no reorg, or it found one and this
    // chain only reports them. Either way the guard has merged the blocks, so
    // the transactions follow. A source that reads the chain store to decide
    // what to fetch leaves out what the store already holds, so its page alone
    // does not cover its own items — only the merged store does, and contract
    // registers read it below.
    | None =>
      switch transactionStore {
      | Some(page) => chainState->ChainState.transactionStore->TransactionStore.merge(page)
      | None => ()
      }

      // Over-fetched events (a merged partition returning an address before its
      // effectiveStartBlock, a wildcard param referencing an address registered
      // after the log's block, or a registration whose own start block is later
      // than its contract's) are already dropped by the source's native gates,
      // so everything here is indexable.
      let newItems = parsedQueueItems
      let itemsWithContractRegister = []
      for idx in 0 to newItems->Array.length - 1 {
        let item = newItems->Array.getUnsafe(idx)
        if item->hasContractRegister {
          itemsWithContractRegister->Array.push(item)
        }
      }

      // Re-check staleness: contract registration is async, so the chain state
      // may have rolled back by the time we apply the fetched items.
      let proceed = (
        ~newRegistrations,
        ~blockRegisterThrough=?,
        ~newItems=newItems,
        ~latestFetchedBlock=latestFetchedBlockNumber,
      ) =>
        if !(state->IndexerState.isStale(~stateId)) {
          applyQueryResponse(
            state,
            ~chainId,
            ~newItems,
            ~newRegistrations,
            ~knownHeight,
            ~latestFetchedBlock,
            ~query,
          )
          switch blockRegisterThrough {
          | Some(through) => chainState->ChainState.markBlockRegistered(~through)
          | None => ()
          }
          ChainMetadata.stage(state)
          scheduleFetch()
          scheduleProcessing()
        }

      // The block passes run with the response that first fetches their
      // blocks, among its events in chain order, and after every earlier unit
      // of the chain's register work.
      let blockRegisterCeiling = Pervasives.min(
        latestFetchedBlockNumber,
        Pervasives.max(knownHeight, chainState->ChainState.knownHeight),
      )
      let withBlockPasses =
        chainState->ChainState.hasBlockRegisters &&
          (itemsWithContractRegister->Utils.Array.notEmpty ||
            chainState->ChainState.canAdvanceBlockRegisters(~through=blockRegisterCeiling))

      switch itemsWithContractRegister {
      | _ if withBlockPasses =>
        let (previous, finish) = chainState->ChainState.queueBlockRegisterRun
        let held =
          chainState->ChainState.holdExtraBudget(
            ~items=Pervasives.max(0, newItems->Array.length - query.itemsEst),
          )
        await previous
        if state->IndexerState.isStale(~stateId) {
          chainState->ChainState.releaseExtraBudget(held)
          finish()
          scheduleFetch()
        } else {
          // A response spanning millions of blocks of an unfiltered handler is
          // applied only once all their passes ran, so it carries at most
          // `maxResponseBlockPasses` past its first block and is cut after
          // them; the partition fetches the rest again.
          let cutAt = switch chainState->ChainState.blockRegisterItemsAfter(
            ~after=Pervasives.max(
              chainState->ChainState.blockRegisterThrough->Option.getOr(blockRegisterCeiling),
              query.fromBlock - 1,
            ),
            ~through=blockRegisterCeiling,
            ~limit=maxResponseBlockPasses,
          ) {
          | Some((_, covered)) if covered < blockRegisterCeiling => Some(covered)
          | _ => None
          }
          let through = cutAt->Option.getOr(blockRegisterCeiling)
          let (newItems, eventItems, latestFetchedBlock) = if cutAt !== None {
            let isKept = item => item->Internal.getItemBlockNumber <= through
            (
              newItems->Array.filter(isKept),
              itemsWithContractRegister->Array.filter(isKept),
              through,
            )
          } else {
            (newItems, itemsWithContractRegister, latestFetchedBlockNumber)
          }
          switch await runResponsePassesOrThrow(~eventItems, ~through, ~runtime, ~chainState) {
          | exception exn =>
            finish()
            IndexerState.errorExit(
              state,
              exn->ErrorHandling.make(~logger=chainState->ChainState.logger),
            )
          | (newRegistrations, blockRegisterThrough) =>
            chainState->ChainState.releaseExtraBudget(held)
            proceed(~newRegistrations, ~blockRegisterThrough?, ~newItems, ~latestFetchedBlock)
            finish()
          }
        }
      | [] => proceed(~newRegistrations=[])
      | _ =>
        // A subgraph's register passes run in chunks, long enough for the pool
        // to admit queries on top of a response it doesn't count yet.
        let held = Env.subgraphMode.contents
          ? Some(
              chainState->ChainState.holdExtraBudget(
                ~items=Pervasives.max(0, newItems->Array.length - query.itemsEst),
              ),
            )
          : None
        switch await runContractRegistersOrThrow(
          ~itemsWithContractRegister,
          ~runtime,
          ~chainState,
        ) {
        | exception exn =>
          IndexerState.errorExit(
            state,
            exn->ErrorHandling.make(~logger=chainState->ChainState.logger),
          )
        | newRegistrations =>
          held->Option.forEach(held => chainState->ChainState.releaseExtraBudget(held))
          proceed(~newRegistrations)
        }
      }
    }
  }

and applyQueryResponse = (
  state: IndexerState.t,
  ~chainId,
  ~newItems,
  ~newRegistrations,
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)

  chainState->ChainState.handleQueryResult(
    ~query,
    ~latestFetchedBlock,
    ~newItems,
    ~newRegistrations,
    ~knownHeight,
  )

  if Env.subgraphMode.contents {
    let fetchState = chainState->ChainState.fetchState
    switch fetchState.optimizedPartitions->FetchState.OptimizedPartitions.getLatestFullyFetchedBlock {
    | Some(frontier) =>
      // A block pass still to run reads at its own block, which can be below
      // every partition.
      let frontier = switch fetchState.blockRegisterThrough {
      | Some(through) => Pervasives.min(frontier, through)
      | None => frontier
      }
      reportRegisterFrontier(chainId->ChainId.toInt, frontier)
    | None => ()
    }
  }

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  if state->IndexerState.exitAfterFirstEventBlock {
    switch newItems->Array.find(item =>
      switch item {
      | Internal.Event(_) => true
      | Block(_) => false
      }
    ) {
    | Some(item) =>
      chainState->ChainState.setEndBlockToFirstEvent(~blockNumber=item->Internal.getItemBlockNumber)
    | None => ()
    }
  }
}

let finishWaitingForNewBlock = (
  state: IndexerState.t,
  ~chainId,
  ~knownHeight,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let chainState = state->IndexerState.getChainState(~chainId)
    chainState->ChainState.updateKnownHeight(~knownHeight)

    // No reorg-threshold check here: scheduleProcessing always runs at least one
    // processNextBatch (even with no items), which owns the entry decision.
    scheduleFetch()
    scheduleProcessing()
  }

// Block passes no response will run: the blocks every partition has already
// fetched (or, with no partition, the blocks up to the head), up to a limit per
// run. Owns its error boundary, as it isn't awaited.
let catchUpBlockRegisters = async (
  state: IndexerState.t,
  ~chainId,
  ~runtime,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  if chainState->ChainState.isBlockRegisterIdle {
    switch chainState->ChainState.nextBlockRegisterItems(
      ~through=chainState->ChainState.blockRegisterFrontier,
      ~limit=blockRegisterWindow,
    ) {
    | None => ()
    | Some((blockItems, through)) =>
      let (_, finish) = chainState->ChainState.queueBlockRegisterRun
      let startedAt = Date.now()
      switch await runRegisterPassesOrThrow(~eventItems=[], ~blockItems, ~runtime, ~chainState) {
      | exception exn =>
        finish()
        IndexerState.errorExit(
          state,
          exn->ErrorHandling.make(~logger=chainState->ChainState.logger),
        )
      | registrations =>
        let isStale = state->IndexerState.isStale(~stateId)
        chainState
        ->ChainState.logger
        ->Logger.trace(
          "Ran block passes",
          ~params={
            "through": through,
            "blockPasses": blockItems->Array.length,
            "registrations": registrations->Array.length,
            "stale": isStale,
            "ms": Date.now() -. startedAt,
          },
        )
        if !isStale {
          chainState->ChainState.applyBlockRegisters(
            ~registrations=registrations->sortRegistrations,
            ~through,
          )
        }
        finish()

        // A run dropped as stale is run again: the fetch tick that would have
        // started it found this one in flight and passed.
        if !isStale {
          ChainMetadata.stage(state)
          scheduleProcessing()
        }
        scheduleFetch()
      }
    }
  }
}

let fetchChain = async (
  state: IndexerState.t,
  chainId,
  ~runtime,
  ~action,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  if !(state->IndexerState.isResolvingReorg) && !(state->IndexerState.isStopped) {
    if chainState->ChainState.hasBlockRegisters {
      catchUpBlockRegisters(
        state,
        ~chainId,
        ~runtime,
        ~stateId,
        ~scheduleFetch,
        ~scheduleProcessing,
      )->Promise.ignore
    }
    let isRealtime = state->IndexerState.isRealtime
    let sourceManager = chainState->ChainState.sourceManager

    // Only affects the WaitingForNewBlock branch of dispatch, where there's
    // nothing to fetch. The line is whether any height is known at all, not
    // whether the head is fetchable yet: a chain held back by its lag is still
    // tracking a head it has, and asking faster would buy nothing. A chain with
    // no height has nothing to show for itself until the first one lands, so it
    // polls at the source's own cadence and earns the normal stall window.
    let reducedPolling = !isRealtime && chainState->ChainState.knownHeight > 0

    // Owns its error boundary: launch doesn't catch, so any failure here (the
    // query, response handling, or dispatch itself) must stop the indexer.
    try {
      await chainState->ChainState.dispatch(
        ~waitForNewBlock=(~knownHeight) =>
          sourceManager->SourceManager.waitForNewBlock(~knownHeight, ~isRealtime, ~reducedPolling),
        ~onNewBlock=(~knownHeight) =>
          finishWaitingForNewBlock(
            state,
            ~chainId,
            ~knownHeight,
            ~stateId,
            ~scheduleFetch,
            ~scheduleProcessing,
          ),
        ~executeQuery=async query => {
          // Caught here (not just by the outer try) so the query promise never
          // rejects: dispatch spins a side-chain off it that would otherwise
          // become an unhandled rejection.
          try {
            let response = await sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=chainState->ChainState.knownHeight,
              ~isRealtime,
              ~reorgableFrom=chainState->ChainState.reorgableFrom(~isRealtime),
            )
            await onQueryResponse(
              state,
              {chainId, response, query},
              ~runtime,
              ~stateId,
              ~scheduleFetch,
              ~scheduleProcessing,
              ~scheduleRollback,
            )
          } catch {
          | exn =>
            IndexerState.errorExit(
              state,
              exn->ErrorHandling.make(~logger=state->IndexerState.logger),
            )
          }
        },
        ~action,
        ~stateId,
      )
    } catch {
    | exn =>
      IndexerState.errorExit(
        state,
        exn->ErrorHandling.make(
          ~logger=state->IndexerState.logger,
          ~msg=IndexerState.unexpectedErrorMsg,
        ),
      )
    }
  }
}
