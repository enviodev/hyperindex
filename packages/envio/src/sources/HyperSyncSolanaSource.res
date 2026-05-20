open Source

exception EventRoutingFailed

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  apiToken: option<string>,
  eventConfigs: array<Internal.svmInstructionEventConfig>,
  clientMaxRetries: int,
  clientTimeoutMillis: int,
}

// Build one HyperSync InstructionSelection per (programId, discriminator) pair.
// Empty programId means the config carries no real program (placeholder), in
// which case we skip — better to over-fetch nothing than ship a degenerate
// query.
let buildInstructionSelections = (
  eventConfigs: array<Internal.svmInstructionEventConfig>,
): array<HyperSyncSolanaClient.QueryTypes.instructionSelection> => {
  eventConfigs->Belt.Array.keepMap(cfg => {
    let programIdString = cfg.programId->SvmTypes.Pubkey.toString
    if programIdString === "" {
      None
    } else {
      // Each instruction owns exactly one dN field — the one matching its
      // declared byte length. The server-side filter is `d{N} IN [..]`.
      let (d1, d2, d4, d8) = switch (cfg.discriminator, cfg.discriminatorByteLen) {
      | (Some(d), 1) => (Some([d]), None, None, None)
      | (Some(d), 2) => (None, Some([d]), None, None)
      | (Some(d), 4) => (None, None, Some([d]), None)
      | (Some(d), 8) => (None, None, None, Some([d]))
      | _ => (None, None, None, None)
      }
      let accountFilters = cfg.accountFilters
      let a0 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 0 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      let a1 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 1 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      let a2 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 2 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      let a3 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 3 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      let a4 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 4 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      let a5 = accountFilters->Belt.Array.keepMap(f =>
        f.position == 5 ? Some(f.values->SvmTypes.Pubkey.toStrings) : None
      )->Belt.Array.get(0)
      Some(
        (
          {
            programId: [programIdString],
            ?d1,
            ?d2,
            ?d4,
            ?d8,
            ?a0,
            ?a1,
            ?a2,
            ?a3,
            ?a4,
            ?a5,
            isInner: ?cfg.isInner,
            includeTransaction: cfg.includeTransaction,
            includeLogs: cfg.includeLogs,
          }: HyperSyncSolanaClient.QueryTypes.instructionSelection
        ),
      )
    }
  })
}

// Synthesize a stable logIndex for an SVM instruction so the FetchState
// ordering machinery (which compares by `(blockNumber, logIndex)`) sorts
// instructions deterministically within a slot. The bit packing fits inside
// JS's 53-bit safe-integer range: transactionIndex ≤ ~10k per slot,
// instruction position ≤ 1000 per tx, depth ≤ ~10. Outer-only instructions
// land at `tx * 65536`; inner ones append depth-weighted offsets.
let synthLogIndex = (instr: HyperSyncSolanaClient.ResponseTypes.instruction) => {
  let tx = instr.transactionIndex
  let addrSum = instr.instructionAddress->Belt.Array.reduce(0, (acc, n) => acc * 1024 + n + 1)
  tx * 65536 + addrSum
}

let serializeInstructionAddress = (addr: array<int>) =>
  addr->Array.map(n => n->Int.toString)->Array.joinUnsafe(",")

let toSvmInstruction = (
  instr: HyperSyncSolanaClient.ResponseTypes.instruction,
): Envio.svmInstruction => {
  programId: instr.programId->SvmTypes.Pubkey.fromStringUnsafe,
  data: instr.data,
  accounts: instr.accounts->SvmTypes.Pubkey.fromStringsUnsafe,
  instructionAddress: instr.instructionAddress,
  isInner: instr.isInner,
  d1: ?instr.d1,
  d2: ?instr.d2,
  d4: ?instr.d4,
  d8: ?instr.d8,
}

let toSvmTransaction = (
  tx: HyperSyncSolanaClient.ResponseTypes.transaction,
): Envio.svmTransaction => {
  signatures: tx.signatures,
  accountKeys: tx.accountKeys->SvmTypes.Pubkey.fromStringsUnsafe,
  feePayer: ?tx.feePayer->Option.map(SvmTypes.Pubkey.fromStringUnsafe),
  success: ?tx.success,
  err: ?tx.err,
  // u64 lamports / compute units arrive as `int` over napi. Convert to
  // `bigint` so the public type stays defensible even for pathological values.
  fee: ?tx.fee->Option.map(BigInt.fromInt),
  computeUnitsConsumed: ?tx.computeUnitsConsumed->Option.map(BigInt.fromInt),
  recentBlockhash: ?tx.recentBlockhash,
  version: ?tx.version,
}

// Probe the discriminator byte-length ordering longest-first. Stops at the
// first router hit. Falls back to the `_none` key (program-wide handler) when
// no discriminator-keyed handler matches.
let probeRouter = (
  router: EventRouter.t<Internal.svmInstructionEventConfig>,
  programId: SvmTypes.Pubkey.t,
  instr: HyperSyncSolanaClient.ResponseTypes.instruction,
  byteLengthsDesc: array<int>,
  ~contractAddress,
  ~indexingAddresses,
) => {
  let probe = (dN: option<string>) => {
    let tag = EventRouter.getSvmEventId(~programId, ~discriminator=dN)
    router->EventRouter.get(
      ~tag,
      ~contractAddress,
      ~blockNumber=instr.slot,
      ~indexingAddresses,
    )
  }

  let result = byteLengthsDesc->Belt.Array.reduce(None, (acc, len) =>
    switch acc {
    | Some(_) => acc
    | None =>
      let candidate = switch len {
      | 8 => instr.d8
      | 4 => instr.d4
      | 2 => instr.d2
      | 1 => instr.d1
      | _ => None
      }
      switch candidate {
      | Some(_) as d => probe(d)
      | None => None
      }
    }
  )

  switch result {
  | Some(_) as hit => hit
  | None => probe(None) // program-wide fallback
  }
}

let make = ({chain, endpointUrl, apiToken, eventConfigs, clientMaxRetries, clientTimeoutMillis}: options): t => {
  let name = "HyperSyncSolana"
  let chainId = chain->ChainMap.Chain.toChainId

  let client = HyperSyncSolanaClient.make(
    ~url=endpointUrl,
    ~apiToken=?apiToken,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~maxNumRetries=clientMaxRetries,
  )

  let (eventRouter, programOrderings) =
    EventRouter.fromSvmEventConfigsOrThrow(eventConfigs, ~chain)

  // programId.toString -> sorted-desc byte lengths
  let orderingByProgram = Dict.make()
  programOrderings->Belt.Array.forEach(o =>
    orderingByProgram->Dict.set(
      o.programId->SvmTypes.Pubkey.toString,
      o.byteLengthsDesc,
    )
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName as _,
    ~indexingAddresses,
    ~knownHeight,
    ~partitionId as _,
    ~selection as _,
    ~retry,
    ~logger,
  ) => {
    let totalTimeRef = Hrtime.makeTimer()
    let pageFetchRef = Hrtime.makeTimer()

    let instructionSelections = buildInstructionSelections(eventConfigs)
    let query: HyperSyncSolanaClient.query = {
      fromSlot: fromBlock,
      toSlot: ?toBlock,
      instructions: instructionSelections,
    }

    Prometheus.SourceRequestCount.increment(
      ~sourceName=name,
      ~chainId,
      ~method="getInstructions",
    )

    let resp = try await client.get(~query) catch {
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching instructions from HyperSync Solana. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }
    let pageFetchTime = pageFetchRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    let parsingRef = Hrtime.makeTimer()

    // Per (slot, transaction_index) lookup for parent transactions.
    let txByKey = Dict.make()
    resp.data.transactions->Belt.Array.forEach(tx => {
      let key =
        tx.slot->Int.toString ++ ":" ++ tx.transactionIndex->Int.toString
      txByKey->Dict.set(key, tx)
    })

    // Per (slot, transaction_index, instruction_address) lookup for logs
    // scoped to a single instruction. `instructionAddress: None` logs are
    // attached to no instruction (rare; usually only system messages).
    let logsByKey = Dict.make()
    resp.data.logs->Belt.Array.forEach(log => {
      switch (log.transactionIndex, log.instructionAddress) {
      | (Some(txIdx), Some(addr)) =>
        let key =
          log.slot->Int.toString ++
          ":" ++
          txIdx->Int.toString ++
          ":" ++
          serializeInstructionAddress(addr)
        switch logsByKey->Dict.get(key) {
        | Some(existing) => existing->Array.push(log)
        | None => logsByKey->Dict.set(key, [log])
        }
      | _ => ()
      }
    })

    let parsedQueueItems = []
    resp.data.instructions->Belt.Array.forEach(instr => {
      let programId = instr.programId->SvmTypes.Pubkey.fromStringUnsafe
      let byteLengths =
        orderingByProgram
        ->Utils.Dict.dangerouslyGetNonOption(instr.programId)
        ->Option.getOr([])

      let contractAddress = instr.programId->Address.unsafeFromString
      let maybeConfig = probeRouter(
        eventRouter,
        programId,
        instr,
        byteLengths,
        ~contractAddress,
        ~indexingAddresses,
      )

      switch maybeConfig {
      | None => ()
      | Some(eventConfig) =>
        let txKey =
          instr.slot->Int.toString ++ ":" ++ instr.transactionIndex->Int.toString
        let maybeTx =
          txByKey->Utils.Dict.dangerouslyGetNonOption(txKey)->Option.map(toSvmTransaction)
        let logKey =
          instr.slot->Int.toString ++
          ":" ++
          instr.transactionIndex->Int.toString ++
          ":" ++
          serializeInstructionAddress(instr.instructionAddress)
        let maybeLogs =
          logsByKey
          ->Utils.Dict.dangerouslyGetNonOption(logKey)
          ->Option.map(
            logs =>
              logs->Array.map((log): Envio.svmLog => {
                kind: log.kind->Option.getOr(""),
                message: log.message->Option.getOr(""),
              }),
          )

        let payload: Envio.svmInstructionEvent = {
          contractName: eventConfig.contractName,
          eventName: eventConfig.name,
          instruction: toSvmInstruction(instr),
          transaction: eventConfig.includeTransaction ? maybeTx : None,
          logs: eventConfig.includeLogs ? maybeLogs : None,
          slot: instr.slot,
          blockTime: None,
        }

        parsedQueueItems
        ->Array.push(
          Internal.Event({
            eventConfig: (eventConfig :> Internal.eventConfig),
            timestamp: 0,
            chain,
            blockNumber: instr.slot,
            logIndex: synthLogIndex(instr),
            event: payload->(
              Utils.magic: Envio.svmInstructionEvent => Internal.event
            ),
          }),
        )
        ->ignore
      }

      let _ = logger
    })

    let parsingTimeElapsed = parsingRef->Hrtime.timeSince->Hrtime.toSecondsFloat
    let heighestSlot = resp.nextSlot - 1

    // C2 ships a no-op reorg guard for SVM: finalized commitment + extremely
    // rare reorgs at finality. C3 wires the extra `queryBlockHash(slot)`
    // route per the Q3 answer.
    let reorgGuard: ReorgDetection.reorgGuard = {
      rangeLastBlock: (
        {
          blockNumber: heighestSlot,
          blockTimestamp: 0,
          blockHash: "",
        }: ReorgDetection.blockDataWithTimestamp
      )->ReorgDetection.generalizeBlockDataWithTimestamp,
      prevRangeLastBlock: None,
    }

    let totalTimeElapsed = totalTimeRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    {
      latestFetchedBlockTimestamp: 0,
      parsedQueueItems,
      latestFetchedBlockNumber: heighestSlot,
      stats: {totalTimeElapsed, parsingTimeElapsed, pageFetchTime},
      knownHeight,
      reorgGuard,
      fromBlockQueried: fromBlock,
    }
  }

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 1000,
    poweredByHyperSync: true,
    getBlockHashes: (~blockNumbers as _, ~logger as _) =>
      // No-op reorg guard means callers never need block hashes for SVM. If a
      // caller does ask, surface the limitation rather than fabricate empty
      // data — C3 will replace this with a real lookup.
      JsError.throwWithMessage(
        "HyperSyncSolanaSource does not support getBlockHashes yet (reorg detection at finalized commitment is no-op in C2)",
      ),
    getHeightOrThrow: async () => {
      let timer = Hrtime.makeTimer()
      let h = await client.getHeight()
      let seconds = timer->Hrtime.timeSince->Hrtime.toSecondsFloat
      Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId, ~method="getHeight")
      Prometheus.SourceRequestCount.addSeconds(
        ~sourceName=name,
        ~chainId,
        ~method="getHeight",
        ~seconds,
      )
      h
    },
    getItemsOrThrow,
  }
}
