open Source

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  apiToken: option<string>,
  onEventRegistrations: array<Internal.svmOnEventRegistration>,
  clientTimeoutMillis: int,
}

// Synthesize a stable logIndex for an SVM instruction so the FetchState
// ordering machinery (which compares by `(blockNumber, logIndex)`) sorts
// instructions deterministically within a slot. The bit packing fits inside
// JS's 53-bit safe-integer range: transactionIndex ≤ ~10k per slot,
// instruction position ≤ 1000 per tx, depth ≤ ~10. Outer-only instructions
// land at `tx * 65536`; inner ones append depth-weighted offsets.
let synthLogIndex = (~transactionIndex, ~instructionAddress) => {
  let addrSum = instructionAddress->Array.reduce(0, (acc, n) => acc * 1024 + n + 1)
  transactionIndex * 65536 + addrSum
}

// Parse the Rust-decoded instruction (args/accounts arrive as JSON strings to
// side-step napi-rs's lack of native JSON passthrough) into the public shape.
let parseDecoded = (
  d: SvmHyperSyncClient.ResponseTypes.decodedInstruction,
): Envio.svmInstructionParams => {
  let args = try JSON.parseOrThrow(d.argsJson) catch {
  | _ => JSON.Object(Dict.make())
  }
  let accounts = try {
    JSON.parseOrThrow(d.accountsJson)->(Utils.magic: JSON.t => dict<string>)
  } catch {
  | _ => Dict.make()
  }
  {
    name: d.name,
    args,
    accounts,
    extraAccounts: d.extraAccounts,
  }
}

// `block` is omitted; it's materialised from the block store at batch prep.
let toSvmInstruction = (
  item: SvmHyperSyncClient.EventItems.item,
  ~programName,
  ~instructionName,
): Envio.svmInstruction => {
  programName,
  instructionName,
  programId: item.programId->SvmTypes.Pubkey.fromStringUnsafe,
  data: item.data,
  accounts: item.accounts->SvmTypes.Pubkey.fromStringsUnsafe,
  instructionAddress: item.instructionAddress,
  isInner: item.isInner,
  d1: ?item.d1,
  d2: ?item.d2,
  d4: ?item.d4,
  d8: ?item.d8,
  params: ?(item.decoded->Option.map(parseDecoded)),
  logs: ?(
    item.logs->Option.map(logs =>
      logs->Array.map((log): Envio.svmLog => {kind: log.kind, message: log.message})
    )
  ),
}

let make = (
  {chain, endpointUrl, apiToken, onEventRegistrations, clientTimeoutMillis}: options,
): t => {
  let name = "SvmHyperSync"

  // The whole per-(instruction, chain) registration set crosses the boundary
  // once at construction; the client derives instruction selections, field
  // selections, Borsh decoders, and the routing index from it.
  let client = SvmHyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken?,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~eventRegistrations=SvmHyperSyncClient.Registration.fromOnEventRegistrations(
      onEventRegistrations,
    ),
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~contractNameByAddress as _,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~itemsTarget,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()
    let pageFetchRef = Performance.now()

    let query: SvmHyperSyncClient.EventItems.query = {
      fromSlot: fromBlock,
      toSlot: toBlock,
      maxNumInstructions: itemsTarget,
      registrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
      addressesByContractName,
    }

    let (resp, transactionStore, blockStore) = try await client.getEventItems(~query) catch {
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching instructions from SVM HyperSync. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }
    let pageFetchTime = pageFetchRef->Performance.secondsSince
    let requestStats = [{Source.method: "getInstructions", seconds: pageFetchTime}]

    let parsingRef = Performance.now()

    // Per-slot blockTime lookup from the response's `blocks` table, for the
    // batch's `latestFetchedBlockTimestamp`. Slots without a block row (rare;
    // usually skipped slots) fall back to `None`.
    let blockTimeBySlot = Dict.make()
    resp.blocks->Array.forEach(b => {
      switch b.blockTime {
      | Some(t) => blockTimeBySlot->Dict.set(b.slot->Int.toString, t)
      | None => ()
      }
    })

    let parsedQueueItems = resp.items->Array.map(item => {
      // Routing happened in Rust; the item references its registration by
      // chain-scoped index.
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex)
      let eventConfig =
        onEventRegistration.eventConfig->(
          Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
        )
      let payload = toSvmInstruction(
        item,
        ~programName=eventConfig.contractName,
        ~instructionName=eventConfig.name,
      )
      Internal.Event({
        onEventRegistration,
        chain,
        blockNumber: item.slot,
        logIndex: synthLogIndex(
          ~transactionIndex=item.transactionIndex,
          ~instructionAddress=item.instructionAddress,
        ),
        // The parent transaction is materialised from the store at batch prep.
        transactionIndex: item.transactionIndex,
        payload: payload->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
      })
    })

    let parsingTimeElapsed = parsingRef->Performance.secondsSince
    let highestSlot = resp.nextSlot - 1
    let latestBlockTime =
      blockTimeBySlot
      ->Utils.Dict.dangerouslyGetNonOption(highestSlot->Int.toString)
      ->Option.getOr(0)

    // Best-effort (slot, blockhash) pairs from the blocks the server returned
    // for this range. Gaps (skipped slots, or slots without matched data) are
    // fine — reorg detection only compares hashes for slots it has observed.
    let blockHashes = resp.blocks->Array.map((b): ReorgDetection.blockData => {
      blockNumber: b.slot,
      blockHash: b.blockhash,
    })

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    {
      latestFetchedBlockTimestamp: latestBlockTime,
      parsedQueueItems,
      // Raw transactions kept in Rust; materialised (selected fields) at batch prep.
      transactionStore: Some(transactionStore),
      // Raw blocks kept in Rust; materialised onto the payload at batch prep.
      blockStore: Some(blockStore),
      latestFetchedBlockNumber: highestSlot,
      stats: {totalTimeElapsed, parsingTimeElapsed, pageFetchTime},
      knownHeight,
      blockHashes,
      fromBlockQueried: fromBlock,
      requestStats,
    }
  }

  // Fetch (slot, blockhash, blockTime) for blocks in an inclusive slot range,
  // paginating on the server's `nextSlot` cursor. `toSlot` is exclusive on the
  // wire, so we request `maxSlot + 1`; the caller filters to the exact slots.
  let queryBlockDataRange = async (~fromSlot, ~toSlot) => {
    let blockDatas = []
    let requestStats = []
    let fromRef = ref(fromSlot)
    let keepGoing = ref(true)
    while keepGoing.contents {
      let query: SvmHyperSyncClient.query = {
        fromSlot: fromRef.contents,
        toSlot: toSlot + 1,
        includeAllBlocks: true,
        fields: {block: [Slot, Blockhash, BlockTime]},
        maxNumBlocks: 1000,
      }
      let timerRef = Performance.now()
      // Block-only query; the store pages are empty.
      let (resp, _, _) = await client.get(~query)
      requestStats
      ->Array.push({Source.method: "getBlockHashes", seconds: timerRef->Performance.secondsSince})
      ->ignore
      resp.data.blocks->Array.forEach(b =>
        blockDatas
        ->Array.push({
          ReorgDetection.blockNumber: b.slot,
          blockHash: b.blockhash,
          blockTimestamp: b.blockTime->Option.getOr(0),
        })
        ->ignore
      )

      // `nextSlot` is the (exclusive) resume cursor. Stop once it passes the
      // range, or fails to advance — the latter guards against an infinite loop.
      if resp.nextSlot > toSlot || resp.nextSlot <= fromRef.contents {
        keepGoing := false
      } else {
        fromRef := resp.nextSlot
      }
    }
    (blockDatas, requestStats)
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _) =>
    switch blockNumbers->Array.get(0) {
    | None => {Source.result: Ok([]), requestStats: []}
    | Some(firstSlot) =>
      try {
        let minSlot = ref(firstSlot)
        let maxSlot = ref(firstSlot)
        let requested = Utils.Set.make()
        blockNumbers->Array.forEach(slot => {
          if slot < minSlot.contents {
            minSlot := slot
          }
          if slot > maxSlot.contents {
            maxSlot := slot
          }
          requested->Utils.Set.add(slot)->ignore
        })
        let (blockDatas, requestStats) = await queryBlockDataRange(
          ~fromSlot=minSlot.contents,
          ~toSlot=maxSlot.contents,
        )
        // Keep one entry per requested slot; drop duplicates and unrelated slots.
        {
          Source.result: Ok(
            blockDatas->Array.filter(data => requested->Utils.Set.delete(data.blockNumber)),
          ),
          requestStats,
        }
      } catch {
      | exn => {Source.result: Error(exn), requestStats: []}
      }
    }

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 1000,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timer = Performance.now()
      let height = await client.getHeight()
      let seconds = timer->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
    },
    getItemsOrThrow,
  }
}
