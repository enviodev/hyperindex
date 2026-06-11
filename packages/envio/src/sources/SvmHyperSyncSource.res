open Source

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  apiToken: option<string>,
  eventConfigs: array<Internal.svmInstructionEventConfig>,
  clientTimeoutMillis: int,
}

// Build HyperSync InstructionSelections from event configs. Each AND-group in
// `cfg.accountFilters` becomes its own selection; selections sharing the same
// `(programId, dN)` are OR-ed by the wire protocol. Empty outer array emits
// one selection with no `aN` set (no account filtering).
//
// Empty programId means the config carries no real program (placeholder), in
// which case we skip — better to over-fetch nothing than ship a degenerate
// query.
let buildInstructionSelections = (eventConfigs: array<Internal.svmInstructionEventConfig>): array<
  SvmHyperSyncClient.QueryTypes.instructionSelection,
> => {
  eventConfigs->Array.flatMap(cfg => {
    let programIdString = cfg.programId->SvmTypes.Pubkey.toString
    if programIdString === "" {
      []
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
      let groups = switch cfg.accountFilters {
      | [] => [[]]
      | gs => gs
      }
      groups->Array.map(group => {
        let pick = position =>
          group
          ->Array.filterMap(
            f => f.position == position ? Some(f.values->SvmTypes.Pubkey.toStrings) : None,
          )
          ->Array.get(0)

        (
          {
            programId: [programIdString],
            ?d1,
            ?d2,
            ?d4,
            ?d8,
            a0: ?pick(0),
            a1: ?pick(1),
            a2: ?pick(2),
            a3: ?pick(3),
            a4: ?pick(4),
            a5: ?pick(5),
            isInner: ?cfg.isInner,
          }: SvmHyperSyncClient.QueryTypes.instructionSelection
        )
      })
    }
  })
}

// Synthesize a stable logIndex for an SVM instruction so the FetchState
// ordering machinery (which compares by `(blockNumber, logIndex)`) sorts
// instructions deterministically within a slot. The bit packing fits inside
// JS's 53-bit safe-integer range: transactionIndex ≤ ~10k per slot,
// instruction position ≤ 1000 per tx, depth ≤ ~10. Outer-only instructions
// land at `tx * 65536`; inner ones append depth-weighted offsets.
let synthLogIndex = (instr: SvmHyperSyncClient.ResponseTypes.instruction) => {
  let tx = instr.transactionIndex
  let addrSum = instr.instructionAddress->Array.reduce(0, (acc, n) => acc * 1024 + n + 1)
  tx * 65536 + addrSum
}

let serializeInstructionAddress = (addr: array<int>) =>
  addr->Array.map(n => n->Int.toString)->Array.joinUnsafe(",")

// Build per-program schema descriptors by grouping eventConfigs by programId,
// returning one descriptor JSON per program. These are handed to the Solana
// client at creation; it builds them into decoders and decodes matching
// instructions inline on `get`.
let buildProgramSchemas = (eventConfigs: array<Internal.svmInstructionEventConfig>): array<
  string,
> => {
  // Group by programId base58 string. Skip events that carry no schema
  // (accounts == [] && args is JSON.Null && definedTypes is JSON.Null —
  // the resolved-empty case from system_config.rs).
  let descriptorsByProgram: dict<{
    "programId": string,
    "definedTypes": JSON.t,
    "instructions": array<{
      "name": string,
      "discriminator": string,
      "accounts": array<string>,
      "args": JSON.t,
    }>,
  }> = Dict.make()

  eventConfigs->Array.forEach(ec => {
    let programIdString = ec.programId->SvmTypes.Pubkey.toString
    if programIdString === "" {
      // Stage 4 placeholder pattern: skip empty program ids.
      ()
    } else {
      let hasSchema = ec.accounts->Array.length > 0 || ec.args !== JSON.Null
      let discriminator = ec.discriminator->Option.getOr("")
      if hasSchema && discriminator !== "" {
        // Inline-schema programs declare no custom types, so `definedTypes`
        // arrives as JSON.Null; the Rust descriptor's `#[serde(default)]` only
        // covers an absent field, not an explicit null, so coalesce here.
        let definedTypes = switch ec.definedTypes {
        | JSON.Null => JSON.Object(Dict.make())
        | other => other
        }
        let existing = descriptorsByProgram->Dict.get(programIdString)
        let descriptor = switch existing {
        | Some(d) => d
        | None => {
            "programId": programIdString,
            "definedTypes": definedTypes,
            "instructions": [],
          }
        }
        let instruction = {
          "name": ec.name,
          "discriminator": discriminator,
          "accounts": ec.accounts,
          "args": ec.args,
        }
        descriptorsByProgram->Dict.set(
          programIdString,
          {
            "programId": descriptor["programId"],
            "definedTypes": descriptor["definedTypes"],
            "instructions": descriptor["instructions"]->Array.concat([instruction]),
          },
        )
      }
    }
  })

  descriptorsByProgram
  ->Dict.valuesToArray
  ->Array.map(descriptor =>
    descriptor
    ->(Utils.magic: {
      "programId": string,
      "definedTypes": JSON.t,
      "instructions": array<{
        "name": string,
        "discriminator": string,
        "accounts": array<string>,
        "args": JSON.t,
      }>,
    } => JSON.t)
    ->JSON.stringify
  )
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

let toSvmInstruction = (
  instr: SvmHyperSyncClient.ResponseTypes.instruction,
  ~programName,
  ~instructionName,
  ~transaction,
  ~logs,
  ~block,
): Envio.svmInstruction => {
  programName,
  instructionName,
  programId: instr.programId->SvmTypes.Pubkey.fromStringUnsafe,
  data: instr.data,
  accounts: instr.accounts->SvmTypes.Pubkey.fromStringsUnsafe,
  instructionAddress: instr.instructionAddress,
  isInner: instr.isInner,
  d1: ?instr.d1,
  d2: ?instr.d2,
  d4: ?instr.d4,
  d8: ?instr.d8,
  params: ?(instr.decoded->Option.map(parseDecoded)),
  ?transaction,
  ?logs,
  block,
}

let toSvmTransaction = (tx: SvmHyperSyncClient.ResponseTypes.transaction): Envio.svmTransaction => {
  signatures: tx.signatures,
  accountKeys: tx.accountKeys->SvmTypes.Pubkey.fromStringsUnsafe,
  feePayer: ?(tx.feePayer->Option.map(SvmTypes.Pubkey.fromStringUnsafe)),
  success: ?tx.success,
  err: ?tx.err,
  // u64 lamports / compute units arrive as `int` over napi. Convert to
  // `bigint` so the public type stays defensible even for pathological values.
  fee: ?(tx.fee->Option.map(BigInt.fromInt)),
  computeUnitsConsumed: ?(tx.computeUnitsConsumed->Option.map(BigInt.fromInt)),
  recentBlockhash: ?tx.recentBlockhash,
  version: ?tx.version,
}

let toSvmTokenBalance = (
  tb: SvmHyperSyncClient.ResponseTypes.tokenBalance,
): Envio.svmTokenBalance => {
  account: ?(tb.account->Option.map(SvmTypes.Pubkey.fromStringUnsafe)),
  mint: ?(tb.mint->Option.map(SvmTypes.Pubkey.fromStringUnsafe)),
  owner: ?(tb.owner->Option.map(SvmTypes.Pubkey.fromStringUnsafe)),
  preAmount: ?tb.preAmount,
  postAmount: ?tb.postAmount,
}

// Probe the discriminator byte-length ordering longest-first. Stops at the
// first router hit. Falls back to the `_none` key (program-wide handler) when
// no discriminator-keyed handler matches.
let probeRouter = (
  router: EventRouter.t<Internal.svmInstructionEventConfig>,
  programId: SvmTypes.Pubkey.t,
  instr: SvmHyperSyncClient.ResponseTypes.instruction,
  byteLengthsDesc: array<int>,
  ~contractAddress,
  ~indexingAddresses,
) => {
  let probe = (dN: option<string>) => {
    let tag = EventRouter.getSvmEventId(~programId, ~discriminator=dN)
    router->EventRouter.get(~tag, ~contractAddress, ~blockNumber=instr.slot, ~indexingAddresses)
  }

  let result = byteLengthsDesc->Array.reduce(None, (acc, len) =>
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

let make = ({chain, endpointUrl, apiToken, eventConfigs, clientTimeoutMillis}: options): t => {
  let name = "HyperSyncSolana"
  let chainId = chain->ChainMap.Chain.toChainId

  // Built once at startup and handed to the client so `get` decodes matching
  // instructions in Rust rather than per-instruction over the napi boundary.
  let programSchemas = buildProgramSchemas(eventConfigs)
  let client = SvmHyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken?,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~programSchemas=?switch programSchemas {
    | [] => None
    | arr => Some(arr)
    },
  )

  let (eventRouter, programOrderings) = EventRouter.fromSvmEventConfigsOrThrow(eventConfigs, ~chain)

  // programId.toString -> sorted-desc byte lengths
  let orderingByProgram = Dict.make()
  programOrderings->Array.forEach(o =>
    orderingByProgram->Dict.set(o.programId->SvmTypes.Pubkey.toString, o.byteLengthsDesc)
  )

  let needsTransactions = eventConfigs->Array.some(cfg => cfg.includeTransaction)
  let needsLogs = eventConfigs->Array.some(cfg => cfg.includeLogs)
  let needsTokenBalances = eventConfigs->Array.some(cfg => cfg.includeTokenBalances)

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
    // Under the server's default merge mode, requesting a table's columns is
    // what opts the matched result set into that join — a table with an empty
    // field list returns no rows (instructions and blocks are exempt), so each
    // opted-into table needs its columns spelled out here.
    let fields: SvmHyperSyncClient.QueryTypes.fieldSelection = {
      block: [Slot, Blockhash, BlockTime],
      transaction: ?(
        needsTransactions
          ? Some([
              Slot,
              TransactionIndex,
              Signatures,
              FeePayer,
              Success,
              Err,
              Fee,
              ComputeUnitsConsumed,
              AccountKeys,
              RecentBlockhash,
              Version,
            ])
          : None
      ),
      log: ?(needsLogs ? Some([Slot, TransactionIndex, InstructionAddress, Kind, Message]) : None),
      tokenBalance: ?(
        needsTokenBalances
          ? Some([Slot, TransactionIndex, Account, Mint, Owner, PreAmount, PostAmount])
          : None
      ),
    }
    let query: SvmHyperSyncClient.query = {
      fromSlot: fromBlock,
      toSlot: ?toBlock,
      instructions: instructionSelections,
      fields,
    }

    Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId, ~method="getInstructions")

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

    // Per-slot unix timestamp lookup from the response's `blocks` table. Slots
    // without a block row (rare; usually skipped slots) fall back to `None`.
    let blockTimeBySlot = Dict.make()
    resp.data.blocks->Array.forEach(b => {
      switch b.blockTime {
      | Some(t) => blockTimeBySlot->Dict.set(b.slot->Int.toString, t)
      | None => ()
      }
    })

    // Per (slot, transaction_index) lookup for parent transactions.
    let txByKey = Dict.make()
    resp.data.transactions->Array.forEach(tx => {
      let key = tx.slot->Int.toString ++ ":" ++ tx.transactionIndex->Int.toString
      txByKey->Dict.set(key, tx)
    })

    // Per (slot, transaction_index, instruction_address) lookup for logs
    // scoped to a single instruction. `instructionAddress: None` logs are
    // attached to no instruction (rare; usually only system messages).
    let logsByKey = Dict.make()
    resp.data.logs->Array.forEach(log => {
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

    let tokenBalancesByTx = Dict.make()
    if needsTokenBalances {
      resp.data.tokenBalances->Array.forEach(tb => {
        switch tb.transactionIndex {
        | Some(txIdx) =>
          let key = tb.slot->Int.toString ++ ":" ++ txIdx->Int.toString
          switch tokenBalancesByTx->Dict.get(key) {
          | Some(existing) => existing->Array.push(tb)
          | None => tokenBalancesByTx->Dict.set(key, [tb])
          }
        | None => ()
        }
      })
    }

    let parsedQueueItems = []
    resp.data.instructions->Array.forEach(instr => {
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
        let txKey = instr.slot->Int.toString ++ ":" ++ instr.transactionIndex->Int.toString
        let maybeTx =
          txByKey->Utils.Dict.dangerouslyGetNonOption(txKey)->Option.map(toSvmTransaction)
        let maybeTx = if eventConfig.includeTokenBalances {
          maybeTx->Option.map(tx => {
            let maybeBalances =
              tokenBalancesByTx
              ->Utils.Dict.dangerouslyGetNonOption(txKey)
              ->Option.map(bals => bals->Array.map(toSvmTokenBalance))
            {...tx, tokenBalances: ?maybeBalances}
          })
        } else {
          maybeTx
        }
        let logKey =
          instr.slot->Int.toString ++
          ":" ++
          instr.transactionIndex->Int.toString ++
          ":" ++
          serializeInstructionAddress(instr.instructionAddress)
        let maybeLogs =
          logsByKey
          ->Utils.Dict.dangerouslyGetNonOption(logKey)
          ->Option.map(logs =>
            logs->Array.map(
              (log): Envio.svmLog => {
                kind: log.kind->Option.getOr(""),
                message: log.message->Option.getOr(""),
              },
            )
          )

        let slotKey = instr.slot->Int.toString
        let blockTime = blockTimeBySlot->Utils.Dict.dangerouslyGetNonOption(slotKey)
        let payload = toSvmInstruction(
          instr,
          ~programName=eventConfig.contractName,
          ~instructionName=eventConfig.name,
          ~transaction=eventConfig.includeTransaction ? maybeTx : None,
          ~logs=eventConfig.includeLogs ? maybeLogs : None,
          ~block={
            slot: instr.slot,
            time: blockTime->Option.getOr(0),
            hash: "",
          },
        )

        parsedQueueItems
        ->Array.push(
          Internal.Event({
            eventConfig: (eventConfig :> Internal.eventConfig),
            timestamp: blockTime->Option.getOr(0),
            chain,
            blockNumber: instr.slot,
            blockHash: "",
            logIndex: synthLogIndex(instr),
            event: payload->(Utils.magic: Envio.svmInstruction => Internal.event),
          }),
        )
        ->ignore
      }

      let _ = logger
    })

    let parsingTimeElapsed = parsingRef->Hrtime.timeSince->Hrtime.toSecondsFloat
    let highestSlot = resp.nextSlot - 1
    let latestBlockTime =
      blockTimeBySlot
      ->Utils.Dict.dangerouslyGetNonOption(highestSlot->Int.toString)
      ->Option.getOr(0)

    // Best-effort (slot, blockhash) pairs from the blocks the server returned
    // for this range. Gaps (skipped slots, or slots without matched data) are
    // fine — reorg detection only compares hashes for slots it has observed.
    let blockHashes = resp.data.blocks->Array.map((b): ReorgDetection.blockData => {
      blockNumber: b.slot,
      blockHash: b.blockhash,
    })

    let totalTimeElapsed = totalTimeRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    {
      latestFetchedBlockTimestamp: latestBlockTime,
      parsedQueueItems,
      latestFetchedBlockNumber: highestSlot,
      stats: {totalTimeElapsed, parsingTimeElapsed, pageFetchTime},
      knownHeight,
      blockHashes,
      fromBlockQueried: fromBlock,
    }
  }

  // Fetch (slot, blockhash, blockTime) for blocks in an inclusive slot range,
  // paginating on the server's `nextSlot` cursor. `toSlot` is exclusive on the
  // wire, so we request `maxSlot + 1`; the caller filters to the exact slots.
  let queryBlockDataRange = async (~fromSlot, ~toSlot) => {
    let blockDatas = []
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
      Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId, ~method="getBlockHashes")
      let resp = await client.get(~query)
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
    blockDatas
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _) =>
    switch blockNumbers->Array.get(0) {
    | None => Ok([])
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
        let blockDatas = await queryBlockDataRange(
          ~fromSlot=minSlot.contents,
          ~toSlot=maxSlot.contents,
        )
        // Keep one entry per requested slot; drop duplicates and unrelated slots.
        Ok(blockDatas->Array.filter(data => requested->Utils.Set.delete(data.blockNumber)))
      } catch {
      | exn => Error(exn)
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
