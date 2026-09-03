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

let namedAccounts = (
  ~idlNames: array<string>,
  ~accountArguments: array<string>,
): dict<Envio.svmInstructionAccount> => {
  let out = Dict.make()
  idlNames->Array.forEachWithIndex((name, i) =>
    switch accountArguments->Array.get(i) {
    | Some(address) =>
      out->Dict.set(
        name,
        {
          Envio.address: address->SvmTypes.Pubkey.fromStringUnsafe,
          accountName: name,
          instructionAccountIndex: i,
        },
      )
    | None => ()
    }
  )
  out
}

let selectedLog = (log: SvmHyperSyncClient.EventItems.log, ~logFields: Utils.Set.t<string>): Envio.svmLog => {
  let out = Dict.make()
  if logFields->Utils.Set.has("kind") {
    switch log.kind->Null.toOption {
    | Some(kind) => out->Dict.set("kind", kind)
    | None => ()
    }
  }
  if logFields->Utils.Set.has("message") {
    switch log.message->Null.toOption {
    | Some(message) => out->Dict.set("message", message)
    | None => ()
    }
  }
  out->(Utils.magic: dict<string> => Envio.svmLog)
}

let setField = (out: dict<unknown>, name: string, value: 'a) =>
  out->Dict.set(name, value->(Utils.magic: 'a => unknown))

// `block` and `transaction` are omitted; they're materialised from the stores
// at batch prep. Named-account `.activity` is attached then too.
// Unselected instruction keys must be omitted, not assigned `undefined`.
let toSvmInstruction = (
  item: SvmHyperSyncClient.EventItems.item,
  ~programName,
  ~instructionName,
  ~eventConfig: Internal.svmInstructionEventConfig,
  ~fieldSelection: Internal.fieldSelection,
): Envio.svmInstruction => {
  let hasSelection = name => fieldSelection.instructionFields->Utils.Set.has(name)
  // A program-wide registration has no configured discriminator, so the whole
  // data stands in, hex-encoded like a configured one would be.
  let discriminator = switch eventConfig.discriminator {
  | Some(d) => d
  | None => "0x" ++ item.data->NodeJs.Buffer.fromUint8Array->NodeJs.Buffer.toHex
  }
  let out = Dict.make()
  out->setField("programName", programName)
  out->setField("instructionName", instructionName)
  out->setField("discriminator", discriminator)
  if hasSelection("programId") {
    out->setField("programId", item.programId->SvmTypes.Pubkey.fromStringUnsafe)
  }
  if hasSelection("data") {
    out->setField("data", item.data)
  }
  if hasSelection("path") {
    out->setField("path", item.path)
  }
  if hasSelection("isInner") {
    out->setField("isInner", item.isInner)
  }
  if hasSelection("args") {
    out->setField("args", item.args)
  }
  if hasSelection("accounts") {
    out->setField(
      "accounts",
      namedAccounts(~idlNames=eventConfig.accounts, ~accountArguments=item.accounts),
    )
  }
  if hasSelection("accountArguments") {
    out->setField("accountArguments", item.accounts->SvmTypes.Pubkey.fromStringsUnsafe)
  }
  if fieldSelection.logFields->Utils.Set.size > 0 {
    out->setField(
      "logs",
      item.logs
      ->Null.getOr([])
      ->Array.map(log => selectedLog(log, ~logFields=fieldSelection.logFields)),
    )
  }
  out->(Utils.magic: dict<unknown> => Envio.svmInstruction)
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
        ~eventConfig,
        ~fieldSelection=onEventRegistration.fieldSelection,
      )
      Internal.Event({
        onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
        chainId,
        blockNumber: item.slot,
        // A slot orders by `(transactionIndex, path)` — the
        // transaction, then the instruction's position in its CPI tree. Both
        // ride the item so the buffer comparator can order on the pair
        // directly; no single integer can hold it (Solana allows a CPI depth
        // of 5, which needs more bits than a JS integer is exact to).
        logIndex: item.transactionIndex,
        orderPath: item.path,
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
