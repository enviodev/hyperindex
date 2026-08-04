open Source

type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  apiToken: option<string>,
  onEventRegistrations: array<Internal.svmOnEventRegistration>,
  clientTimeoutMillis: int,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
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
  {
    chainId,
    endpointUrl,
    apiToken,
    onEventRegistrations,
    clientTimeoutMillis,
    addressStore,
  }: options,
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
    ~addressStore,
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
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
      maxNumInstructions: ?itemsTarget,
      registrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
      clientFilteredContracts: selection.clientFilteredContracts,
    }

    let (resp, transactionStore, blockStore) = try await client.getEventItems(
      ~query,
      ~addressSet,
    ) catch {
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
        chainId,
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

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    {
      latestFetchedBlockTimestamp: latestBlockTime,
      parsedQueueItems,
      // Raw transactions kept in Rust; materialised (selected fields) at batch prep.
      transactionStore: Some(transactionStore),
      // Raw blocks kept in Rust; materialised onto the payload at batch prep.
      // Their (slot, blockhash) pairs also drive reorg detection on merge.
      blockStore,
      latestFetchedBlockNumber: highestSlot,
      stats: {totalTimeElapsed, parsingTimeElapsed, pageFetchTime},
      knownHeight,
      fromBlockQueried: fromBlock,
      requestStats,
    }
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _) => {
    let (result, requestStats) = try {
      let (blockStore, requestStats) = await client.getBlockHashes(~blockNumbers)
      (Ok(blockStore), requestStats)
    } catch {
    | exn => {
        let failure = exn->Source.unpackNativeRequestFailure
        (Error(failure->HyperSync.mapRateLimitedFailure), failure.requestStats)
      }
    }
    {Source.result, requestStats}
  }

  {
    name,
    sourceFor: Sync,
    chainId,
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
