// EVM simulate block schema — all fields present with defaults for non-nullable ones.
// Nullable fields (from Internal.evmNullableBlockFields) use S.null → option<T>.
let evmSimulateBlockSchema = S.schema(s =>
  {
    // Non-nullable fields with defaults
    "number": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "timestamp": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "hash": s.matches(S.null(S.string)->S.Option.getOr("")),
    "parentHash": s.matches(S.null(S.string)->S.Option.getOr("")),
    "sha3Uncles": s.matches(S.null(S.string)->S.Option.getOr("")),
    "logsBloom": s.matches(S.null(S.string)->S.Option.getOr("")),
    "transactionsRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "stateRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "receiptsRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "miner": s.matches(
      S.null(Address.schema)->S.Option.getOr(
        Address.unsafeFromString("0x0000000000000000000000000000000000000000"),
      ),
    ),
    "extraData": s.matches(S.null(S.string)->S.Option.getOr("")),
    "size": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "gasLimit": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "gasUsed": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    // Nullable fields
    "nonce": s.matches(S.null(S.bigint)),
    "difficulty": s.matches(S.null(S.bigint)),
    "totalDifficulty": s.matches(S.null(S.bigint)),
    "uncles": s.matches(S.null(S.array(S.string))),
    "baseFeePerGas": s.matches(S.null(S.bigint)),
    "blobGasUsed": s.matches(S.null(S.bigint)),
    "excessBlobGas": s.matches(S.null(S.bigint)),
    "parentBeaconBlockRoot": s.matches(S.null(S.string)),
    "withdrawalsRoot": s.matches(S.null(S.string)),
    "l1BlockNumber": s.matches(S.null(S.int)),
    "sendCount": s.matches(S.null(S.string)),
    "sendRoot": s.matches(S.null(S.string)),
    "mixHash": s.matches(S.null(S.string)),
  }
)

type evmSimulateBlock = {number: int, timestamp: int, hash: string}

let parseEvmSimulateBlock = (
  ~defaultBlockNumber: int,
  ~blockJson: option<JSON.t>,
): Internal.eventBlock => {
  let block = switch blockJson {
  | Some(json) => json->S.convertOrThrow(evmSimulateBlockSchema)
  | None =>
    Dict.make()
    ->(Utils.magic: dict<unit> => JSON.t)
    ->S.convertOrThrow(evmSimulateBlockSchema)
  }
  let block = block->(Utils.magic: _ => Internal.eventBlock)
  let blockFields = block->(Utils.magic: Internal.eventBlock => evmSimulateBlock)

  // Only set block number when user didn't provide one (schema defaults to 0)
  if blockJson->Option.isNone || blockFields.number === 0 {
    let blockDict = block->(Utils.magic: Internal.eventBlock => dict<unknown>)
    blockDict->Dict.set("number", defaultBlockNumber->(Utils.magic: int => unknown))
  }
  block
}

// Fuel simulate block schema — fields: id, height, time
let fuelSimulateBlockSchema = S.schema(s =>
  {
    "id": s.matches(S.null(S.string)->S.Option.getOr("")),
    "height": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "time": s.matches(S.null(S.int)->S.Option.getOr(0)),
  }
)

type fuelSimulateBlock = {height: int, time: int, id: string}

let parseFuelSimulateBlock = (
  ~defaultBlockNumber: int,
  ~blockJson: option<JSON.t>,
): Internal.eventBlock => {
  let block = switch blockJson {
  | Some(json) => json->S.convertOrThrow(fuelSimulateBlockSchema)
  | None =>
    Dict.make()
    ->(Utils.magic: dict<unit> => JSON.t)
    ->S.convertOrThrow(fuelSimulateBlockSchema)
  }
  let block = block->(Utils.magic: _ => Internal.eventBlock)
  let blockFields = block->(Utils.magic: Internal.eventBlock => fuelSimulateBlock)

  // Only set block height when user didn't provide one (schema defaults to 0)
  if blockJson->Option.isNone || blockFields.height === 0 {
    let blockDict = block->(Utils.magic: Internal.eventBlock => dict<unknown>)
    blockDict->Dict.set("height", defaultBlockNumber->(Utils.magic: int => unknown))
  }
  block
}

// Fuel simulate transaction schema — fields: id
let fuelSimulateTransactionSchema = S.schema(s =>
  {
    "id": s.matches(S.null(S.string)->S.Option.getOr("")),
  }
)

let parseFuelSimulateTransaction = (
  ~transactionJson: option<JSON.t>,
): Internal.eventTransaction => {
  let transaction = switch transactionJson {
  | Some(json) => json->S.convertOrThrow(fuelSimulateTransactionSchema)
  | None =>
    Dict.make()
    ->(Utils.magic: dict<unit> => JSON.t)
    ->S.convertOrThrow(fuelSimulateTransactionSchema)
  }
  transaction->(Utils.magic: _ => Internal.eventTransaction)
}

// Raw JSON item from user - discriminated by presence of "contract"+"event" keys
type rawSimulateItem

@get external getContract: rawSimulateItem => option<string> = "contract"
@get external getEvent: rawSimulateItem => option<string> = "event"
@get external getProgram: rawSimulateItem => option<string> = "program"
@get external getInstruction: rawSimulateItem => option<string> = "instruction"
@get external getBlock: rawSimulateItem => option<JSON.t> = "block"
@get external getTransaction: rawSimulateItem => option<dict<unknown>> = "transaction"

// A simulated value as a JSON-RPC node spells it: quantities in hex, the one
// decimal field as a number, and nothing for a value the test left empty. A
// block's nonce is 8 bytes of data rather than a quantity, so it keeps its
// leading zeros.
let toRpcValue = (value: unknown, ~key, ~isBlock): option<JSON.t> =>
  switch typeof(value) {
  | #bigint if isBlock && key === "nonce" =>
    Some(
      JSON.String(
        "0x" ++
        value
        ->(Utils.magic: unknown => bigint)
        ->BigInt.toString(~radix=16)
        ->String.padStart(16, "0"),
      ),
    )
  | #bigint =>
    Some(JSON.String("0x" ++ value->(Utils.magic: unknown => bigint)->BigInt.toString(~radix=16)))
  | #number if key === "l1FeeScalar" => Some(value->(Utils.magic: unknown => JSON.t))
  | #number =>
    Some(JSON.String("0x" ++ value->(Utils.magic: unknown => int)->Int.toString(~radix=16)))
  | #string if value === %raw(`""`) => None
  | #string | #object if value !== %raw(`null`) => Some(value->(Utils.magic: unknown => JSON.t))
  | _ => None
  }

// The hash a simulated transaction given none takes: its block number, then
// its index, each in 16 bytes.
let defaultTransactionHash = (~blockNumber, ~transactionIndex) =>
  `0x${blockNumber->Int.toString(~radix=16)->String.padStart(32, "0")}${transactionIndex
    ->Int.toString(~radix=16)
    ->String.padStart(32, "0")}`

let toRpcObject = (fields: dict<unknown>, ~isBlock) => {
  let object = Dict.make()
  fields->Dict.forEachWithKey((value, key) =>
    switch value->toRpcValue(~key, ~isBlock) {
    | Some(value) => object->Dict.set(key, value)
    | None => ()
    }
  )
  object
}

// A simulated transaction as a JSON-RPC node spells it, at its place in the
// block. A row is keyed and decoded with its hash, so one left out is made from
// that place, and a mined transaction succeeded unless the test says it reverted.
let transactionRow = (fields: dict<unknown>, ~blockNumber, ~transactionIndex) => {
  let row = fields->toRpcObject(~isBlock=false)
  row->Dict.set("blockNumber", JSON.String("0x" ++ blockNumber->Int.toString(~radix=16)))
  row->Dict.set("transactionIndex", JSON.String("0x" ++ transactionIndex->Int.toString(~radix=16)))
  if !(row->Dict.has("hash")) {
    row->Dict.set("hash", JSON.String(defaultTransactionHash(~blockNumber, ~transactionIndex)))
  }
  if !(row->Dict.has("status")) {
    row->Dict.set("status", JSON.String("0x1"))
  }
  row
}

let findEventConfig = (~config: Config.t, ~contractName: string, ~eventName: string) => {
  let found = ref(None)
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === contractName {
        contract.events->Array.forEach(
          eventConfig => {
            if eventConfig.name === eventName {
              found := Some(eventConfig)
            }
          },
        )
      }
    })
  })
  found.contents
}

let dummySrcAddress = Address.unsafeFromString("0x0000000000000000000000000000000000000000")

// First address configured for `contractName` on the simulated chain. Only the
// simulated chain is consulted — a contract's address on another chain has no
// meaning here.
let firstContractAddress = (~chainConfig: Config.chain, ~contractName: string): option<
  Address.t,
> => {
  let found = ref(None)
  chainConfig.contracts->Array.forEach(contract => {
    if found.contents->Option.isNone && contract.name === contractName {
      found := contract.addresses->Array.get(0)
    }
  })
  found.contents
}

let deriveSrcAddress = (
  ~providedSrcAddress: option<Address.t>,
  ~eventConfig: Internal.eventConfig,
  ~chainConfig: Config.chain,
  ~config: Config.t,
): Address.t => {
  switch providedSrcAddress {
  // Canonicalize to the configured casing; the fallback addresses below already
  // come from the parsed config and need no normalization. Relaxed (not
  // Config.normalizeUserAddress) so test placeholders like "0xfoo" are allowed.
  | Some(addr) => config->Config.normalizeSimulateAddress(addr)
  | None =>
    if (
      HandlerRegister.isWildcard(
        ~contractName=eventConfig.contractName,
        ~eventName=eventConfig.name,
      )
    ) {
      dummySrcAddress
    } else {
      switch firstContractAddress(~chainConfig, ~contractName=eventConfig.contractName) {
      | Some(addr) => addr
      | None => dummySrcAddress
      }
    }
  }
}

type parseResult = {
  items: array<Internal.item>,
  itemSimulateIndexes: array<int>,
  getBlock: int => option<Internal.eventBlock>,
  page: option<BufferPage.t>,
  transactions: array<Config.simulatedTransaction>,
}

type svmSimActivity = {
  address: string,
  transactionAccountIndex?: int,
  isSigner?: bool,
  isWritable?: bool,
  lamports?: {pre?: bigint, post?: bigint},
  token?: {
    mint?: string,
    owner?: string,
    decimals?: int,
    preAmount?: bigint,
    postAmount?: bigint,
  },
}

type svmSimTransaction = {
  transactionIndex?: int,
  signature?: string,
  allSignatures?: array<string>,
  feePayer?: string,
  success?: bool,
  err?: string,
  fee?: bigint,
  computeUnitsConsumed?: bigint,
  accountKeys?: array<string>,
  recentBlockhash?: string,
  version?: string,
  accountActivities?: array<svmSimActivity>,
}

let liveRegistrationsFor = (
  ~config: Config.t,
  ~chainId: ChainId.t,
  ~eventConfig: Internal.eventConfig,
) =>
  HandlerRegister.getSimulateOnEventRegistrations(
    ~config,
    ~chainId,
    ~eventConfig,
  )->Array.filter(reg => !HandlerRegister.isDroppedByWhere(~config, reg))

// A simulated block with the defaults filled in, and its number. An SVM slot
// has no defaults to fill beyond the slot itself: every other field is one a
// slot that produced no block lacks too.
let parseBlock = (~ecosystem: Ecosystem.name, ~defaultBlockNumber, ~blockJson) =>
  switch ecosystem {
  | Fuel =>
    let block = parseFuelSimulateBlock(~defaultBlockNumber, ~blockJson)
    (block, (block->(Utils.magic: Internal.eventBlock => fuelSimulateBlock)).height)
  | Evm =>
    let block = parseEvmSimulateBlock(~defaultBlockNumber, ~blockJson)
    (block, (block->(Utils.magic: Internal.eventBlock => evmSimulateBlock)).number)
  | Svm =>
    let block = switch blockJson {
    | Some(json) => json->(Utils.magic: JSON.t => dict<unknown>)->Dict.copy
    | None => Dict.make()
    }
    let slot = switch block->Dict.get("slot") {
    | Some(slot) => slot->(Utils.magic: unknown => int)
    | None => defaultBlockNumber
    }
    block->Dict.set("slot", slot->(Utils.magic: int => unknown))
    (block->(Utils.magic: dict<unknown> => Internal.eventBlock), slot)
  }

let parse = (
  ~simulateItems: array<JSON.t>,
  ~config: Config.t,
  ~chainConfig: Config.chain,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
): parseResult => {
  let chainId = chainConfig.id
  let startBlock = chainConfig->Config.startBlockOrZero
  let currentBlock = ref(startBlock)
  let currentLogIndex = ref(0)

  let items = []
  let itemSimulateIndexes = []
  // One block per number, which the block handlers that select fields read: a
  // block given on its own, otherwise the first one an item carried.
  let blocks: dict<Internal.eventBlock> = Dict.make()
  let ownBlockNumbers = Utils.Set.make()
  let addCarriedBlock = (block, ~blockNumber) => {
    let key = blockNumber->Int.toString
    if blocks->Dict.get(key)->Option.isNone {
      blocks->Dict.set(key, block)
    }
  }
  let svmTxs: array<BufferPage.svmTxInput> = []
  let svmActivities: array<BufferPage.svmActivityInput> = []
  let svmBlocks: array<BufferPage.observedBlock> = []
  let simulatedTransactions: array<Config.simulatedTransaction> = []
  // Per block, its transactions' fields by index. A simulated transaction and
  // the events of it share one, each giving the fields it knows.
  let evmTransactionFields: dict<dict<dict<unknown>>> = Dict.make()
  let transactionsOf = blockNumber => {
    let blockKey = blockNumber->Int.toString
    switch evmTransactionFields->Dict.get(blockKey) {
    | Some(transactions) => transactions
    | None =>
      let transactions = Dict.make()
      evmTransactionFields->Dict.set(blockKey, transactions)
      transactions
    }
  }
  // A transaction's own fields, checked, and its index: given, or `default`.
  let parseTransactionOrThrow = (fields: dict<unknown>, ~default, ~fail) => {
    fields
    ->Dict.keysToArray
    ->Array.forEach(key =>
      if !(Evm.transactionFields->Array.includes(key)) {
        fail(`unknown transaction field "${key}"`)->ignore
      }
    )
    switch fields
    ->Dict.get("transactionIndex")
    ->Option.filter(index => index !== %raw(`undefined`)) {
    | None => default
    | Some(index)
      if typeof(index) === #number &&
      Math.floor(index->(Utils.magic: unknown => float)) ===
        index->(Utils.magic: unknown => float) &&
      index->(Utils.magic: unknown => float) >= 0. =>
      index->(Utils.magic: unknown => int)
    | Some(index) =>
      fail(
        `transactionIndex must be a non-negative integer, got ${index
          ->JSON.stringifyAny
          ->Option.getOr("undefined")}`,
      )
    }
  }
  let addTransactionFields = (fields: dict<unknown>, ~blockNumber, ~transactionIndex, ~fail) => {
    let transactions = transactionsOf(blockNumber)
    let indexKey = transactionIndex->Int.toString
    switch transactions->Dict.get(indexKey) {
    | None => transactions->Dict.set(indexKey, fields->Dict.copy)
    | Some(held) =>
      let heldValues = held->toRpcObject(~isBlock=false)
      fields
      ->toRpcObject(~isBlock=false)
      ->Dict.forEachWithKey((value, key) =>
        switch heldValues->Dict.get(key) {
        | None => held->Dict.set(key, fields->Dict.getUnsafe(key))
        // RPC values are hex, which reads the same in either case.
        | Some(heldValue)
          if JSON.stringify(heldValue)->String.toLowerCase ===
            JSON.stringify(value)->String.toLowerCase => ()
        | Some(_) =>
          fail(
            `block ${blockNumber->Int.toString} already has a transaction at index ${indexKey} with another "${key}"`,
          )->ignore
        }
      )
    }
  }
  // Coordinate "block:logIndex" -> the index of the first item that claimed it,
  // used to reject two items resolving to the same (block, logIndex).
  let seenCoordinates = Dict.make()

  simulateItems->Array.forEachWithIndex((rawJson, itemIndex) => {
    let raw = rawJson->(Utils.magic: JSON.t => rawSimulateItem)

    switch (config.ecosystem.name, raw->getProgram, raw->getInstruction) {
    | (Evm, None, None)
      if raw->getContract->Option.isNone &&
      raw->getEvent->Option.isNone &&
      raw->getTransaction->Option.isSome =>
      let fail = message =>
        JsError.throwWithMessage(
          `simulate: transaction at index ${itemIndex->Int.toString} on chain ${chainId->ChainId.toString}: ${message}`,
        )
      let (block, blockNumber) = parseBlock(
        ~ecosystem=Evm,
        ~defaultBlockNumber=currentBlock.contents,
        ~blockJson=raw->getBlock,
      )
      block->addCarriedBlock(~blockNumber)
      currentBlock := blockNumber
      let transaction = raw->getTransaction->Option.getUnsafe
      let transactions = transactionsOf(blockNumber)
      let transactionIndex = transaction->parseTransactionOrThrow(
        ~default=transactions
        ->Dict.keysToArray
        ->Array.reduce(0, (next, index) =>
          Pervasives.max(next, index->Int.fromString->Option.getOr(0) + 1)
        ),
        ~fail,
      )
      if (
        simulatedTransactions->Array.some(simulated =>
          simulated.blockNumber === blockNumber && simulated.transactionIndex === transactionIndex
        )
      ) {
        fail(
          `block ${blockNumber->Int.toString} already has a transaction at index ${transactionIndex->Int.toString}. Give each one a distinct transactionIndex (or omit it to take the next free one).`,
        )
      }
      transaction->addTransactionFields(~blockNumber, ~transactionIndex, ~fail)
      simulatedTransactions
      ->Array.push({simulateIndex: itemIndex, blockNumber, transactionIndex})
      ->ignore
    | (Evm | Svm, None, None)
      if raw->getContract->Option.isNone &&
      raw->getEvent->Option.isNone &&
      raw->getBlock->Option.isSome =>
      let (block, blockNumber) = parseBlock(
        ~ecosystem=config.ecosystem.name,
        ~defaultBlockNumber=currentBlock.contents,
        ~blockJson=raw->getBlock,
      )
      if ownBlockNumbers->Utils.Set.has(blockNumber) {
        JsError.throwWithMessage(
          `simulate: item at index ${itemIndex->Int.toString} on chain ${chainId->ChainId.toString} is a second block ${blockNumber->Int.toString}. Give each block's fields in one item.`,
        )
      }
      ownBlockNumbers->Utils.Set.add(blockNumber)->ignore
      blocks->Dict.set(blockNumber->Int.toString, block)
      currentBlock := blockNumber

    | (Svm, Some(programName), Some(instructionName)) =>
      let eventConfig = switch findEventConfig(
        ~config,
        ~contractName=programName,
        ~eventName=instructionName,
      ) {
      | Some(ec) => ec
      | None =>
        JsError.throwWithMessage(
          `simulate: Instruction "${instructionName}" not found on program "${programName}". ` ++ `Check that the program and instruction names match your config.yaml.`,
        )
      }
      let svmEventConfig =
        eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
      let item = rawJson->(Utils.magic: JSON.t => Envio.svmSimulateItem)
      let rawItem = rawJson->(Utils.magic: JSON.t => {..})
      let blockJson: option<JSON.t> =
        rawItem["block"]->(Utils.magic: 'a => Nullable.t<JSON.t>)->Nullable.toOption
      let slot = switch item.slot {
      | Some(s) => s
      | None =>
        switch blockJson {
        | Some(bj) =>
          switch bj->(Utils.magic: JSON.t => dict<JSON.t>)->Dict.get("slot") {
          | Some(v) =>
            v
            ->(Utils.magic: JSON.t => Nullable.t<int>)
            ->Nullable.toOption
            ->Option.getOr(currentBlock.contents)
          | None => currentBlock.contents
          }
        | None => currentBlock.contents
        }
      }
      currentBlock := slot
      let transaction = switch item.transaction {
      | Some(tx) => tx->(Utils.magic: unknown => svmSimTransaction)
      | None => {}
      }
      let transactionIndex = transaction.transactionIndex->Option.getOr(0)
      let path = item.path->Option.getOr([0])
      let programId =
        item.programId->Option.getOr(svmEventConfig.programId->SvmTypes.Pubkey.toString)
      // `accountArguments` is the list the call carries, so it stands as
      // written: a short one leaves the later slots absent, the way a
      // truncated instruction reads from chain. Named accounts speak about
      // some slots instead, so they go back onto their declared positions and
      // a slot the item leaves out carries the program id — chain's own
      // stand-in for an absent account, which reads back as absent for an
      // optional slot and as the program for a required one.
      let accountArguments = switch item.accountArguments {
      | Some(args) => args
      | None =>
        switch item.accounts {
        | Some(named) =>
          svmEventConfig.accounts->Array.map(slot =>
            switch slot->Internal.svmAccountSlotName {
            | None => programId
            | Some(name) => named->Dict.get(name)->Option.mapOr(programId, ({address}) => address)
            }
          )
        | None => []
        }
      }
      let data = switch (item.data, svmEventConfig.discriminator) {
      | (Some(data), _) => data
      | (None, Some(discriminator)) =>
        discriminator
        ->String.replace("0x", "")
        ->NodeJs.Buffer.fromHex
        ->Uint8Array.fromArrayLikeOrIterable
      | (None, None) => Uint8Array.fromLength(0)
      }
      let args = item.args->Option.getOr(Dict.make()->(Utils.magic: dict<unknown> => unknown))
      let logs = item.logs->Option.map(logs =>
        logs->Array.map(
          (log): SvmHyperSyncClient.Items.log => {
            kind: log.kind->Nullable.fromOption,
            message: log.message->Nullable.fromOption,
          },
        )
      )

      let liveRegistrations = liveRegistrationsFor(~config, ~chainId, ~eventConfig)
      if liveRegistrations->Utils.Array.isEmpty {
        JsError.throwWithMessage(
          `simulate: no handler runs for instruction "${instructionName}" on program "${programName}". Register a handler with indexer.onInstruction before simulating it.`,
        )
      }

      svmTxs
      ->Array.push({
        slot,
        transactionIndex,
        signature: ?transaction.signature,
        allSignatures: ?transaction.allSignatures,
        feePayer: ?transaction.feePayer,
        success: ?transaction.success,
        err: ?transaction.err,
        fee: ?transaction.fee,
        computeUnitsConsumed: ?transaction.computeUnitsConsumed,
        accountKeys: ?transaction.accountKeys,
        recentBlockhash: ?transaction.recentBlockhash,
        version: ?transaction.version,
      })
      ->ignore
      switch transaction.accountActivities {
      | Some(rows) =>
        rows->Array.forEach(activity =>
          svmActivities
          ->Array.push({
            BufferPage.slot,
            transactionIndex,
            account: activity.address,
            accountIndex: ?activity.transactionAccountIndex,
            isSigner: ?activity.isSigner,
            isWritable: ?activity.isWritable,
            preBalance: ?(activity.lamports->Option.flatMap(l => l.pre)),
            postBalance: ?(activity.lamports->Option.flatMap(l => l.post)),
            mint: ?(activity.token->Option.flatMap(t => t.mint)),
            owner: ?(activity.token->Option.flatMap(t => t.owner)),
            decimals: ?(activity.token->Option.flatMap(t => t.decimals)),
            preAmount: ?(activity.token->Option.flatMap(t => t.preAmount)),
            postAmount: ?(activity.token->Option.flatMap(t => t.postAmount)),
          })
          ->ignore
        )
      | None => ()
      }
      let blockTime = switch item.block {
      | Some(block) => block.time
      | None => None
      }
      let blockHash = switch item.block {
      | Some(block) => block.hash
      | None => None
      }
      let (block, blockSlot) = parseBlock(~ecosystem=Svm, ~defaultBlockNumber=slot, ~blockJson)
      if blockSlot !== slot {
        JsError.throwWithMessage(
          `simulate: item at index ${itemIndex->Int.toString} on chain ${chainId->ChainId.toString} is at slot ${slot->Int.toString} but its block is slot ${blockSlot->Int.toString}. Give the slot once.`,
        )
      }
      block->addCarriedBlock(~blockNumber=slot)
      svmBlocks
      ->Array.push({
        blockNumber: slot,
        ?blockHash,
        blockTimestamp: ?blockTime,
      })
      ->ignore

      liveRegistrations->Array.forEach(reg => {
        let onEventRegistrationIndex = onEventRegistrations->Array.length
        let onEventRegistration = {...reg, index: onEventRegistrationIndex}
        onEventRegistrations->Array.push(onEventRegistration)->ignore
        let payload = SvmEventItem.toSvmInstruction(
          {
            slot,
            transactionIndex,
            path,
            programId,
            accounts: accountArguments,
            data,
            isInner: item.isInner->Option.getOr(false),
            // As the Rust client does: present exactly when this registration
            // selected `args`.
            args: onEventRegistration.fieldSelection.instructionFields->Utils.Set.has("args")
              ? Nullable.make(args)
              : Nullable.undefined,
            logs: logs->Nullable.fromOption,
          },
          ~programName,
          ~instructionName,
          ~eventConfig=svmEventConfig,
          ~fieldSelection=onEventRegistration.fieldSelection,
        )
        let payloadDict = payload->(Utils.magic: Envio.svmInstruction => dict<unknown>)
        payloadDict->Dict.set("srcAddress", programId->(Utils.magic: string => unknown))
        itemSimulateIndexes->Array.push(itemIndex)->ignore
        items
        ->Array.push(
          Internal.Event({
            onEventRegistration,
            chainId,
            blockNumber: slot,
            logIndex: transactionIndex,
            orderPath: path,
            transactionIndex,
            payload: payload->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
          }),
        )
        ->ignore
      })

    | (Svm, _, _) =>
      JsError.throwWithMessage(`simulate: Invalid item. Each item must have "program" and "instruction" fields, or be a "block" on its own.`)

    | (_, _, _) =>
      let (contractName, eventName) = switch (raw->getContract, raw->getEvent) {
      | (Some(c), Some(e)) => (c, e)
      | _ =>
        JsError.throwWithMessage(
          `simulate: Invalid item. Each item must have "contract" and "event" fields${config.ecosystem.name ===
              Evm
              ? `, or be a "block" on its own`
              : ""}.`,
        )
      }
      // Event simulate item
      let eventConfig = switch findEventConfig(~config, ~contractName, ~eventName) {
      | Some(ec) => ec
      | None =>
        JsError.throwWithMessage(
          `simulate: Event "${eventName}" not found on contract "${contractName}". ` ++ `Check that the contract and event names match your config.yaml.`,
        )
      }

      // Parse event item fields
      let item = rawJson->(Utils.magic: JSON.t => Envio.evmSimulateItem)

      // Parse params using the simulate schema — fills missing fields with defaults
      let paramsJson: JSON.t = switch item.params {
      | Some(json) => json
      | None => Dict.make()->(Utils.magic: dict<unit> => JSON.t)
      }
      let params = paramsJson->S.convertOrThrow(eventConfig.simulateParamsSchema)

      // An explicit logIndex advances the auto-increment counter past itself, so a
      // later item that omits logIndex picks up after it instead of colliding.
      let logIndex = switch item.logIndex {
      | Some(li) =>
        if li >= currentLogIndex.contents {
          currentLogIndex := li + 1
        }
        li
      | None =>
        let li = currentLogIndex.contents
        currentLogIndex := li + 1
        li
      }

      let srcAddress = deriveSrcAddress(
        ~providedSrcAddress=item.srcAddress,
        ~eventConfig,
        ~chainConfig,
        ~config,
      )

      let rawItem = rawJson->(Utils.magic: JSON.t => {..})
      let blockJson: option<JSON.t> =
        rawItem["block"]->(Utils.magic: 'a => Nullable.t<JSON.t>)->Nullable.toOption
      let transactionJson: option<JSON.t> =
        rawItem["transaction"]->(Utils.magic: 'a => Nullable.t<JSON.t>)->Nullable.toOption
      let (block, blockNumber) = parseBlock(
        ~ecosystem=config.ecosystem.name,
        ~defaultBlockNumber=currentBlock.contents,
        ~blockJson,
      )
      block->addCarriedBlock(~blockNumber)
      // An EVM event's transaction and block enter the buffer as a simulated
      // transaction's do, and are read back by its key.
      let (transaction, transactionIndex) = switch config.ecosystem.name {
      | Fuel => (Some(parseFuelSimulateTransaction(~transactionJson)), 0)
      | Evm =>
        let fail = message =>
          JsError.throwWithMessage(
            `simulate: event at index ${itemIndex->Int.toString} on chain ${chainId->ChainId.toString}: ${message}`,
          )
        let fields =
          transactionJson->Option.mapOr(Dict.make(), json =>
            json->(Utils.magic: JSON.t => dict<unknown>)
          )
        let transactionIndex = fields->parseTransactionOrThrow(~default=0, ~fail)
        fields->addTransactionFields(~blockNumber, ~transactionIndex, ~fail)
        (None, transactionIndex)
      | Svm => JsError.throwWithMessage("simulate is not supported for SVM ecosystem")
      }

      // Update currentBlock for subsequent items
      currentBlock := blockNumber

      // A simulate item must land on a distinct (block, logIndex): event ordering
      // and the dead-input tracker both key on it. Catch explicit duplicates and
      // explicit-vs-auto-increment collisions here, naming both offending indices.
      let coordinate = `${blockNumber->Int.toString}:${logIndex->Int.toString}`
      switch seenCoordinates->Dict.get(coordinate) {
      | Some(firstIndex) =>
        JsError.throwWithMessage(
          `simulate: items at index ${firstIndex->Int.toString} and ${itemIndex->Int.toString} on chain ${chainId->ChainId.toString} both resolve to block ${blockNumber->Int.toString}, logIndex ${logIndex->Int.toString}. Give each item a distinct logIndex (or omit logIndex so they auto-increment).`,
        )
      | None => seenCoordinates->Dict.set(coordinate, itemIndex)
      }

      // Fan the simulated event out to every registration that would actually
      // run here the way real matching does (one item per registration).
      // Registrations are built the same way `HandlerRegister.finishRegistration`
      // does at startup (not stubs), so the address filter and `where` behave
      // identically to real indexing — the dead-input tracker relies on the
      // source's address gate actually dropping unmatched items. Drop registrations
      // whose `where` excludes this chain (they wouldn't be fetched live), so a
      // missing handler surfaces below instead of silently running nothing.
      let liveRegistrations = liveRegistrationsFor(~config, ~chainId, ~eventConfig)
      if liveRegistrations->Utils.Array.isEmpty {
        JsError.throwWithMessage(
          `simulate: no handler runs for event "${eventName}" on contract "${contractName}"${switch config.chainMap
            ->ChainMap.values
            ->Array.length {
            | 1 => ""
            | _ => ` on chain ${chainId->ChainId.toString}`
            }}. Register a handler with indexer.onEvent (and check any \`where\` filter isn't excluding this chain) before simulating it.`,
        )
      }
      liveRegistrations->Array.forEach(reg => {
        // Append into the registration array that the chain state will own and
        // put that same registration object directly on the simulated item.
        let onEventRegistrationIndex = onEventRegistrations->Array.length
        let onEventRegistration = {...reg, index: onEventRegistrationIndex}
        onEventRegistrations->Array.push(onEventRegistration)->ignore

        itemSimulateIndexes->Array.push(itemIndex)->ignore
        items
        ->Array.push(
          Internal.Event({
            onEventRegistration,
            chainId,
            blockNumber,
            logIndex,
            transactionIndex,
            payload: (
              {
                contractName: eventConfig.contractName,
                eventName: eventConfig.name,
                params,
                chainId,
                srcAddress,
                logIndex,
                ?transaction,
                block: ?switch config.ecosystem.name {
                | Fuel => Some(block)
                | Evm | Svm => None
                },
              }: Evm.payload
            )->Evm.fromPayload,
          }),
        )
        ->ignore
      })
    }
  })

  // A slot the chain skipped has no block, so on SVM a slot nothing simulated
  // a block for has none either, where an EVM or Fuel block takes defaults.
  let getBlock = blockNumber =>
    switch (blocks->Dict.get(blockNumber->Int.toString), config.ecosystem.name) {
    | (Some(_) as block, _) => block
    | (None, Svm) => None
    | (None, Evm | Fuel) =>
      let (block, _) = parseBlock(
        ~ecosystem=config.ecosystem.name,
        ~defaultBlockNumber=blockNumber,
        ~blockJson=None,
      )
      Some(block)
    }

  switch config.ecosystem.name {
  | Svm => {
      items,
      itemSimulateIndexes,
      getBlock,
      page: Some(BufferPage.fromSvmJs(svmTxs, svmActivities, svmBlocks)),
      transactions: [],
    }
  | Evm if evmTransactionFields->Dict.keysToArray->Utils.Array.notEmpty => {
      items,
      itemSimulateIndexes,
      getBlock,
      transactions: simulatedTransactions,
      // A transaction handler reads its block from the buffer, with the
      // defaults an event's block gets.
      page: Some(
        BufferPage.fromEvmJs(
          ~transactions=evmTransactionFields
          ->Dict.toArray
          ->Array.flatMap(((blockKey, transactions)) =>
            transactions
            ->Dict.toArray
            ->Array.map(((indexKey, fields)) =>
              fields->transactionRow(
                ~blockNumber=blockKey->Int.fromString->Option.getOrThrow,
                ~transactionIndex=indexKey->Int.fromString->Option.getOrThrow,
              )
            )
          ),
          ~blocks=evmTransactionFields
          ->Dict.keysToArray
          ->Array.filterMap(blockKey =>
            blockKey
            ->Int.fromString
            ->Option.flatMap(getBlock)
            ->Option.map(block => {
              let row =
                block
                ->(Utils.magic: Internal.eventBlock => dict<unknown>)
                ->toRpcObject(~isBlock=true)

              // Every block row holds its hash, which an event's block
              // defaults to empty.
              if row->Dict.get("hash")->Option.isNone {
                row->Dict.set(
                  "hash",
                  JSON.String(
                    `0x${blockKey
                      ->Int.fromString
                      ->Option.getOr(0)
                      ->Int.toString(~radix=16)
                      ->String.padStart(64, "0")}`,
                  ),
                )
              }
              row
            })
          ),
        ),
      ),
    }
  | _ => {
      items,
      itemSimulateIndexes,
      getBlock,
      page: None,
      transactions: [],
    }
  }
}

// Apply simulate source config from processConfig JSON to a Config.t
// This patches chainMap entries that have simulate items with CustomSources
let patchConfig = (
  ~config: Config.t,
  ~processConfig: JSON.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
): Config.t => {
  let processChains: option<dict<JSON.t>> =
    (processConfig->(Utils.magic: JSON.t => {..}))["chains"]->Nullable.toOption
  switch processChains {
  | Some(chainsDict) =>
    let newChainMap = config.chainMap->ChainMap.mapWithKey((chainId, chainConfig) => {
      let chainIdStr = chainId->ChainId.toString
      switch chainsDict->Dict.get(chainIdStr) {
      | Some(processChainJson) =>
        let raw = processChainJson->(Utils.magic: JSON.t => {..})
        let simulateRaw: option<array<JSON.t>> = raw["simulate"]->Nullable.toOption
        switch simulateRaw {
        | Some(simulateItems) =>
          let chainRegistrations = switch registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(
            chainIdStr,
          ) {
          | Some(registrations) => registrations
          | None =>
            let registrations: HandlerRegister.chainRegistrations = {
              onEventRegistrations: [],
              onBlockRegistrations: [],
              onTransactionRegistrations: [],
            }
            registrationsByChainId->Dict.set(chainIdStr, registrations)
            registrations
          }
          let startBlock: int = raw["startBlock"]->(Utils.magic: 'a => int)
          let endBlock: int = raw["endBlock"]->(Utils.magic: 'a => int)
          // Parse with the process's startBlock so items default into the range
          // the source will be queried over; the source now filters by range.
          let chainConfig = {...chainConfig, startBlock: Config.Block(startBlock), endBlock}
          let {items, itemSimulateIndexes, getBlock, page, transactions} = parse(
            ~simulateItems,
            ~config,
            ~chainConfig,
            ~onEventRegistrations=chainRegistrations.onEventRegistrations,
          )
          {
            ...chainConfig,
            sourceConfig: Config.SimulateSourceConfig({
              items,
              itemSimulateIndexes,
              getBlock,
              endBlock,
              ?page,
              transactions,
            }),
          }
        | None => chainConfig
        }
      | None => chainConfig
      }
    })
    {...config, chainMap: newChainMap}
  | None => config
  }
}
