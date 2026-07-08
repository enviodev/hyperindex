open Source

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  apiToken: option<string>,
  onEventRegistrations: array<Internal.svmOnEventRegistration>,
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

// `block` is omitted; it's materialised from the block store at batch prep.
let toSvmInstruction = (
  instr: SvmHyperSyncClient.ResponseTypes.instruction,
  ~programName,
  ~instructionName,
  ~logs,
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
  ?logs,
}

// Probe the discriminator byte-length ordering longest-first. Stops at the
// first router hit. Falls back to the `_none` key (program-wide handler) when
// no discriminator-keyed handler matches.
let probeRouter = (
  router: EventRouter.t<Internal.svmOnEventRegistration>,
  programId: SvmTypes.Pubkey.t,
  instr: SvmHyperSyncClient.ResponseTypes.instruction,
  byteLengthsDesc: array<int>,
  ~contractAddress,
  ~contractNameByAddress,
) => {
  let probe = (dN: option<string>) => {
    let tag = EventRouter.getSvmEventId(~programId, ~discriminator=dN)
    router->EventRouter.get(~tag, ~contractAddress, ~contractNameByAddress)
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

// Map a selected transaction field to the extra query-side column it needs.
// `transactionIndex` is always fetched as the store key, and `tokenBalances`
// lives in a separate table (requested via `needsTokenBalances`), so neither
// adds a transaction column here.
let toQueryTxField = (field: Internal.svmTransactionField): option<
  SvmHyperSyncClient.QueryTypes.transactionField,
> =>
  switch field {
  | TransactionIndex => None
  | Signatures => Some(Signatures)
  | FeePayer => Some(FeePayer)
  | Success => Some(Success)
  | Err => Some(Err)
  | Fee => Some(Fee)
  | ComputeUnitsConsumed => Some(ComputeUnitsConsumed)
  | AccountKeys => Some(AccountKeys)
  | RecentBlockhash => Some(RecentBlockhash)
  | Version => Some(Version)
  | TokenBalances => None
  }

// Map a selected block field to its HyperSync query column. Slot/Blockhash/
// BlockTime are requested unconditionally (needed for reorg detection and the
// item's slot/timestamp), so selecting `slot`/`time`/`hash` adds no extra column.
let toQueryBlockField = (field: Internal.svmBlockField): option<
  SvmHyperSyncClient.QueryTypes.blockField,
> =>
  switch field {
  | Slot | Time | Hash => None
  | Height => Some(BlockHeight)
  | ParentSlot => Some(ParentSlot)
  | ParentHash => Some(ParentBlockhash)
  }

let make = (
  {chain, endpointUrl, apiToken, onEventRegistrations, clientTimeoutMillis}: options,
): t => {
  let name = "SvmHyperSync"

  // Definitions drive query/decode building; the registrations drive routing
  // (they carry `isWildcard` and become each decoded item's `onEventRegistration`).
  let eventConfigs =
    onEventRegistrations->Array.map(reg =>
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    )

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

  let (eventRouter, programOrderings) = EventRouter.fromSvmEventConfigsOrThrow(
    onEventRegistrations,
    ~chain,
  )

  // programId.toString -> sorted-desc byte lengths
  let orderingByProgram = Dict.make()
  programOrderings->Array.forEach(o =>
    orderingByProgram->Dict.set(o.programId->SvmTypes.Pubkey.toString, o.byteLengthsDesc)
  )

  let needsLogs = eventConfigs->Array.some(cfg => cfg.includeLogs)

  // Union of selected transaction fields across the chain's events. Drives both
  // the query column selection (fetch only what's used) and the materialisation
  // mask. `slot`/`transactionIndex` are always fetched as the store key.
  let selectedTxFields = Utils.Set.make()
  eventConfigs->Array.forEach(cfg =>
    cfg.selectedTransactionFields
    ->(Utils.magic: Utils.Set.t<string> => Utils.Set.t<Internal.svmTransactionField>)
    ->Utils.Set.forEach(field => selectedTxFields->Utils.Set.add(field)->ignore)
  )
  let needsTokenBalances = selectedTxFields->Utils.Set.has(Internal.TokenBalances)
  let txQueryFields = {
    // Slot + TransactionIndex are always fetched so the store can be keyed by
    // (slot, transactionIndex).
    let fields: array<SvmHyperSyncClient.QueryTypes.transactionField> = [Slot, TransactionIndex]
    selectedTxFields
    ->Utils.Set.toArray
    ->Array.forEach(field =>
      switch toQueryTxField(field) {
      | Some(queryField) => fields->Array.push(queryField)
      | None => ()
      }
    )
    fields
  }
  // The transaction table is fetched only when a selected field is actually read
  // off a stored transaction record. `transactionIndex` materialises from the
  // store key and `tokenBalances` lives in its own table, so neither requires it.
  let needsTransactions =
    selectedTxFields
    ->Utils.Set.toArray
    ->Array.some(field =>
      switch field {
      | Internal.TransactionIndex | Internal.TokenBalances => false
      | _ => true
      }
    )

  // Union of selected block fields across the chain's events. `slot`/`time`/
  // `hash` are always fetched (as Slot/BlockTime/Blockhash); the rest are added
  // only when an instruction selected them.
  let blockQueryFields = {
    let fields: array<SvmHyperSyncClient.QueryTypes.blockField> = [Slot, Blockhash, BlockTime]
    let selected = Utils.Set.make()
    eventConfigs->Array.forEach(cfg =>
      cfg.selectedBlockFields->Utils.Set.forEach(field => selected->Utils.Set.add(field)->ignore)
    )
    selected->Utils.Set.forEach(field =>
      switch field->toQueryBlockField {
      | Some(queryField) => fields->Array.push(queryField)->ignore
      | None => ()
      }
    )
    fields
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName as _,
    ~contractNameByAddress,
    ~knownHeight,
    ~partitionId as _,
    ~selection as _,
    ~itemsTarget,
    ~retry,
    ~logger,
  ) => {
    let totalTimeRef = Performance.now()
    let pageFetchRef = Performance.now()

    let instructionSelections = buildInstructionSelections(eventConfigs)
    // Under the server's default merge mode, requesting a table's columns is
    // what opts the matched result set into that join — a table with an empty
    // field list returns no rows (instructions and blocks are exempt), so each
    // opted-into table needs its columns spelled out here.
    let fields: SvmHyperSyncClient.QueryTypes.fieldSelection = {
      block: blockQueryFields,
      transaction: ?(needsTransactions ? Some(txQueryFields) : None),
      log: ?(needsLogs ? Some([Slot, TransactionIndex, InstructionAddress, Kind, Message]) : None),
      tokenBalance: ?(
        needsTokenBalances
          ? Some([Slot, TransactionIndex, Account, Mint, Owner, PreAmount, PostAmount])
          : None
      ),
    }
    // `toBlock` is inclusive, but `toSlot` is exclusive on the wire — without
    // the +1 a bounded range stalls one slot short of its end.
    let query: SvmHyperSyncClient.query = {
      fromSlot: fromBlock,
      toSlot: ?(toBlock->Option.map(toBlock => toBlock + 1)),
      instructions: instructionSelections,
      fields,
      maxNumInstructions: itemsTarget,
    }

    let (resp, transactionStore, blockStore) = try await client.get(~query) catch {
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
    resp.data.blocks->Array.forEach(b => {
      switch b.blockTime {
      | Some(t) => blockTimeBySlot->Dict.set(b.slot->Int.toString, t)
      | None => ()
      }
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
        ~contractNameByAddress,
      )

      switch maybeConfig {
      | None => ()
      | Some(onEventRegistration) =>
        let eventConfig =
          onEventRegistration.eventConfig->(
            Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
          )
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

        let payload = toSvmInstruction(
          instr,
          ~programName=eventConfig.contractName,
          ~instructionName=eventConfig.name,
          ~logs=eventConfig.includeLogs ? maybeLogs : None,
        )

        parsedQueueItems
        ->Array.push(
          Internal.Event({
            onEventRegistration,
            chain,
            blockNumber: instr.slot,
            logIndex: synthLogIndex(instr),
            // The parent transaction is materialised from the store at batch prep.
            transactionIndex: instr.transactionIndex,
            payload: payload->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
          }),
        )
        ->ignore
      }

      let _ = logger
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
    let blockHashes = resp.data.blocks->Array.map((b): ReorgDetection.blockData => {
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
