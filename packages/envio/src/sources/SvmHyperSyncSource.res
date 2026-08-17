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
      // A rate limit or a replica behind the head is recoverable and has its own
      // backoff and failover, so it must not be buried in a generic retry.
      HyperSync.reraiseIfRecoverable(exn)
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
        // A slot orders by `(transactionIndex, instructionAddress)` — the
        // transaction, then the instruction's position in its CPI tree. Both
        // ride the item so the buffer comparator can order on the pair
        // directly; no single integer can hold it (Solana allows a CPI depth
        // of 5, which needs more bits than a JS integer is exact to).
        logIndex: item.transactionIndex,
        orderPath: item.instructionAddress,
        // The parent transaction is materialised from the store at batch prep.
        transactionIndex: item.transactionIndex,
        payload: payload->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
      })
    })

    let parsingTimeElapsed = parsingRef->Performance.secondsSince
    let highestSlot = resp.nextSlot - 1

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    {
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

  // Called through the client rather than passed as a value: the client is a
  // napi class, so a detached method reference loses the instance it belongs to.
  let getBlockHashes = HyperSync.makeGetBlockHashes(
    ~query=(~blockNumbers) => client.getBlockHashes(~blockNumbers),
  )

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
