type unchecksummedEthAddress = string

module QueryTypes = {
  type blockFieldOptions =
    | @as("number") Number
    | @as("hash") Hash
    | @as("parent_hash") ParentHash
    | @as("nonce") Nonce
    | @as("sha3_uncles") Sha3Uncles
    | @as("logs_bloom") LogsBloom
    | @as("transactions_root") TransactionsRoot
    | @as("state_root") StateRoot
    | @as("receipts_root") ReceiptsRoot
    | @as("miner") Miner
    | @as("difficulty") Difficulty
    | @as("total_difficulty") TotalDifficulty
    | @as("extra_data") ExtraData
    | @as("size") Size
    | @as("gas_limit") GasLimit
    | @as("gas_used") GasUsed
    | @as("timestamp") Timestamp
    | @as("uncles") Uncles
    | @as("base_fee_per_gas") BaseFeePerGas

  let blockFieldOptionsSchema = S.union([
    S.literal(Number),
    S.literal(Hash),
    S.literal(ParentHash),
    S.literal(Nonce),
    S.literal(Sha3Uncles),
    S.literal(LogsBloom),
    S.literal(TransactionsRoot),
    S.literal(StateRoot),
    S.literal(ReceiptsRoot),
    S.literal(Miner),
    S.literal(Difficulty),
    S.literal(TotalDifficulty),
    S.literal(ExtraData),
    S.literal(Size),
    S.literal(GasLimit),
    S.literal(GasUsed),
    S.literal(Timestamp),
    S.literal(Uncles),
    S.literal(BaseFeePerGas),
  ])

  type blockFieldSelection = array<blockFieldOptions>

  let blockFieldSelectionSchema = S.array(blockFieldOptionsSchema)

  type transactionFieldOptions =
    | @as("block_hash") BlockHash
    | @as("block_number") BlockNumber
    | @as("from") From
    | @as("gas") Gas
    | @as("gas_price") GasPrice
    | @as("hash") Hash
    | @as("input") Input
    | @as("nonce") Nonce
    | @as("to") To
    | @as("transaction_index") TransactionIndex
    | @as("value") Value
    | @as("v") V
    | @as("r") R
    | @as("s") S
    | @as("max_priority_fee_per_gas") MaxPriorityFeePerGas
    | @as("max_fee_per_gas") MaxFeePerGas
    | @as("chain_id") ChainId
    | @as("cumulative_gas_used") CumulativeGasUsed
    | @as("effective_gas_price") EffectiveGasPrice
    | @as("gas_used") GasUsed
    | @as("contract_address") ContractAddress
    | @as("logs_bloom") LogsBloom
    | @as("type") Type
    | @as("root") Root
    | @as("status") Status
    | @as("sighash") Sighash

  let transactionFieldOptionsSchema = S.union([
    S.literal(BlockHash),
    S.literal(BlockNumber),
    S.literal(From),
    S.literal(Gas),
    S.literal(GasPrice),
    S.literal(Hash),
    S.literal(Input),
    S.literal(Nonce),
    S.literal(To),
    S.literal(TransactionIndex),
    S.literal(Value),
    S.literal(V),
    S.literal(R),
    S.literal(S),
    S.literal(MaxPriorityFeePerGas),
    S.literal(MaxFeePerGas),
    S.literal(ChainId),
    S.literal(CumulativeGasUsed),
    S.literal(EffectiveGasPrice),
    S.literal(GasUsed),
    S.literal(ContractAddress),
    S.literal(LogsBloom),
    S.literal(Type),
    S.literal(Root),
    S.literal(Status),
    S.literal(Sighash),
  ])

  type transactionFieldSelection = array<transactionFieldOptions>

  let transactionFieldSelectionSchema = S.array(transactionFieldOptionsSchema)

  type logFieldOptions =
    | @as("removed") Removed
    | @as("log_index") LogIndex
    | @as("transaction_index") TransactionIndex
    | @as("transaction_hash") TransactionHash
    | @as("block_hash") BlockHash
    | @as("block_number") BlockNumber
    | @as("address") Address
    | @as("data") Data
    | @as("topic0") Topic0
    | @as("topic1") Topic1
    | @as("topic2") Topic2
    | @as("topic3") Topic3

  let logFieldOptionsSchema = S.union([
    S.literal(Removed),
    S.literal(LogIndex),
    S.literal(TransactionIndex),
    S.literal(TransactionHash),
    S.literal(BlockHash),
    S.literal(BlockNumber),
    S.literal(Address),
    S.literal(Data),
    S.literal(Topic0),
    S.literal(Topic1),
    S.literal(Topic2),
    S.literal(Topic3),
  ])

  type logFieldSelection = array<logFieldOptions>

  let logFieldSelectionSchema = S.array(logFieldOptionsSchema)

  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  let fieldSelectionSchema = S.object((. s) => {
    block: ?s.field("block", S.null(blockFieldSelectionSchema)),
    transaction: ?s.field("transaction", S.null(transactionFieldSelectionSchema)),
    log: ?s.field("log", S.null(logFieldSelectionSchema)),
  })

  type logParams = {
    address?: array<Ethers.ethAddress>,
    topics: array<array<Ethers.EventFilter.topic>>,
  }

  let logParamsSchema = S.object((. s) => {
    address: ?s.field("address", S.null(S.array(Ethers.ethAddressSchema))),
    topics: s.field("topics", S.array(S.array(S.string))),
  })

  type transactionParams = {
    from?: array<Ethers.ethAddress>,
    to?: array<Ethers.ethAddress>,
    sighash?: array<string>,
  }

  let transactionParamsSchema = S.object((. s) => {
    from: ?s.field("from", S.nullable(S.array(Ethers.ethAddressSchema))),
    to: ?s.field("to", S.nullable(S.array(Ethers.ethAddressSchema))),
    sighash: ?s.field("sighash", S.nullable(S.array(S.string))),
  })

  type postQueryBody = {
    fromBlock: int,
    toBlockExclusive?: int,
    logs?: array<logParams>,
    transactions?: array<transactionParams>,
    fieldSelection: fieldSelection,
    maxNumLogs?: int,
    includeAllBlocks?: bool,
  }

  // TODO: Do we want to use S.null or S.option
  let postQueryBodySchema = S.object((. s) => {
    fromBlock: s.field("from_block", S.int),
    toBlockExclusive: ?s.field("to_block", S.null(S.int)),
    logs: ?s.field("logs", S.null(S.array(logParamsSchema))),
    transactions: ?s.field("transactions", S.null(S.array(transactionParamsSchema))),
    fieldSelection: s.field("field_selection", fieldSelectionSchema),
    maxNumLogs: ?s.field("max_num_logs", S.null(S.int)),
    includeAllBlocks: ?s.field("include_all_blocks", S.null(S.bool)),
  })
}

module ResponseTypes = {
  // TODO: Should we use S.nullable or S.null (?)
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type blockData = {
    number?: int,
    hash?: string,
    parentHash?: string,
    nonce?: int, //nullable
    sha3Uncles?: string,
    logsBloom?: string,
    transactionsRoot?: string,
    stateRoot?: string,
    receiptsRoot?: string,
    miner?: unchecksummedEthAddress,
    difficulty?: Ethers.BigInt.t, //nullable
    totalDifficulty?: Ethers.BigInt.t, //nullable
    extraData?: string,
    size?: Ethers.BigInt.t,
    gasLimit?: Ethers.BigInt.t,
    gasUsed?: Ethers.BigInt.t,
    timestamp?: Ethers.BigInt.t,
    uncles?: string, //nullable
    baseFeePerGas?: Ethers.BigInt.t, //nullable
  }

  let blockDataSchema = S.object((. s) => {
    number: ?s.field("number", S.nullable(S.int)),
    hash: ?s.field("hash", S.nullable(S.string)),
    parentHash: ?s.field("parent_hash", S.nullable(S.string)),
    nonce: ?s.field("nonce", S.nullable(S.int)),
    sha3Uncles: ?s.field("sha3_uncles", S.nullable(S.string)),
    logsBloom: ?s.field("logs_bloom", S.nullable(S.string)),
    transactionsRoot: ?s.field("transactions_root", S.nullable(S.string)),
    stateRoot: ?s.field("state_root", S.nullable(S.string)),
    receiptsRoot: ?s.field("receipts_root", S.nullable(S.string)),
    miner: ?s.field("miner", S.nullable(S.string)),
    difficulty: ?s.field("difficulty", S.nullable(Ethers.BigInt.schema)),
    totalDifficulty: ?s.field("total_difficulty", S.nullable(Ethers.BigInt.schema)),
    extraData: ?s.field("extra_data", S.nullable(S.string)),
    size: ?s.field("size", S.nullable(Ethers.BigInt.schema)),
    gasLimit: ?s.field("gas_limit", S.nullable(Ethers.BigInt.schema)),
    gasUsed: ?s.field("gas_used", S.nullable(Ethers.BigInt.schema)),
    timestamp: ?s.field("timestamp", S.nullable(Ethers.BigInt.schema)),
    uncles: ?s.field("unclus", S.nullable(S.string)),
    baseFeePerGas: ?s.field("base_fee_per_gas", S.nullable(Ethers.BigInt.schema)),
  })

  // TODO: Should we use S.nullable or S.null (?)
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type transactionData = {
    blockHash?: string,
    blockNumber?: int,
    from?: unchecksummedEthAddress, //nullable
    gas?: Ethers.BigInt.t,
    gasPrice?: Ethers.BigInt.t, //nullable
    hash?: string,
    input?: string,
    nonce?: int,
    to?: unchecksummedEthAddress, //nullable
    transactionIndex?: int,
    value?: Ethers.BigInt.t,
    v?: string, //nullable
    r?: string, //nullable
    s?: string, //nullable
    maxPriorityFeePerGas?: Ethers.BigInt.t, //nullable
    maxFeePerGas?: Ethers.BigInt.t, //nullable
    chainId?: int, //nullable
    cumulativeGasUsed?: Ethers.BigInt.t,
    effectiveGasPrice?: Ethers.BigInt.t,
    gasUsed?: Ethers.BigInt.t,
    contractAddress?: unchecksummedEthAddress, //nullable
    logsBoom?: string,
    type_?: int, //nullable
    root?: string, //nullable
    status?: int, //nullable
    sighash?: string, //nullable
  }

  let transactionDataSchema = S.object((. s) => {
    blockHash: ?s.field("block_hash", S.nullable(S.string)),
    blockNumber: ?s.field("block_number", S.nullable(S.int)),
    from: ?s.field("from", S.nullable(S.string)),
    gas: ?s.field("gas", S.nullable(Ethers.BigInt.schema)),
    gasPrice: ?s.field("gas_price", S.nullable(Ethers.BigInt.schema)),
    hash: ?s.field("hash", S.nullable(S.string)),
    input: ?s.field("input", S.nullable(S.string)),
    nonce: ?s.field("nonce", S.nullable(S.int)),
    to: ?s.field("to", S.nullable(S.string)),
    transactionIndex: ?s.field("transaction_index", S.nullable(S.int)),
    value: ?s.field("value", S.nullable(Ethers.BigInt.schema)),
    v: ?s.field("v", S.nullable(S.string)),
    r: ?s.field("r", S.nullable(S.string)),
    s: ?s.field("s", S.nullable(S.string)),
    maxPriorityFeePerGas: ?s.field("max_priority_fee_per_gas", S.nullable(Ethers.BigInt.schema)),
    maxFeePerGas: ?s.field("max_fee_per_gas", S.nullable(Ethers.BigInt.schema)),
    chainId: ?s.field("chain_id", S.nullable(S.int)),
    cumulativeGasUsed: ?s.field("cumulative_gas_used", S.nullable(Ethers.BigInt.schema)),
    effectiveGasPrice: ?s.field("effective_gas_price", S.nullable(Ethers.BigInt.schema)),
    gasUsed: ?s.field("gas_used", S.nullable(Ethers.BigInt.schema)),
    contractAddress: ?s.field("contract_address", S.nullable(S.string)),
    logsBoom: ?s.field("logs_bloom", S.nullable(S.string)),
    type_: ?s.field("type", S.nullable(S.int)),
    root: ?s.field("root", S.nullable(S.string)),
    status: ?s.field("status", S.nullable(S.int)),
    sighash: ?s.field("sighash", S.nullable(S.string)),
  })

  // TODO: Should we use S.nullable or S.null (?)
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type logData = {
    removed?: bool, //nullable
    index?: int,
    transactionIndex?: int,
    transactionHash?: string,
    blockHash?: string,
    blockNumber?: int,
    address?: unchecksummedEthAddress,
    data?: string,
    topic0?: Ethers.EventFilter.topic, //nullable
    topic1?: Ethers.EventFilter.topic, //nullable
    topic2?: Ethers.EventFilter.topic, //nullable
    topic3?: Ethers.EventFilter.topic, //nullable
  }

  let logDataSchema = S.object((. s) => {
    removed: ?s.field("removed", S.nullable(S.bool)),
    index: ?s.field("log_index", S.nullable(S.int)),
    transactionIndex: ?s.field("transaction_index", S.nullable(S.int)),
    transactionHash: ?s.field("transaction_hash", S.nullable(S.string)),
    blockHash: ?s.field("block_hash", S.nullable(S.string)),
    blockNumber: ?s.field("block_number", S.nullable(S.int)),
    address: ?s.field("address", S.nullable(S.string)),
    data: ?s.field("data", S.nullable(S.string)),
    topic0: ?s.field("topic0", S.nullable(S.string)),
    topic1: ?s.field("topic1", S.nullable(S.string)),
    topic2: ?s.field("topic2", S.nullable(S.string)),
    topic3: ?s.field("topic3", S.nullable(S.string)),
  })

  // TODO: Should we use S.nullable or S.null (?)dule ResponseTypes = {
  type data = {
    blocks?: array<blockData>,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  let dataSchema = S.object((. s) => {
    blocks: ?s.field("blocks", S.array(blockDataSchema)->S.nullable),
    transactions: ?s.field("transactions", S.array(transactionDataSchema)->S.nullable),
    logs: ?s.field("logs", S.array(logDataSchema)->S.nullable),
  })

  type queryResponse = {
    data: array<data>,
    archiveHeight: int,
    nextBlock: int,
    totalTime: int,
  }

  let queryResponseSchema = S.object((. s) => {
    data: s.field("data", S.array(dataSchema)),
    archiveHeight: s.field("archive_height", S.int),
    nextBlock: s.field("next_block", S.int),
    totalTime: s.field("total_execution_time", S.int),
  })
}

let executeHyperSyncQuery = (~serverUrl, ~postQueryBody: QueryTypes.postQueryBody): promise<
  result<ResponseTypes.queryResponse, QueryHelpers.queryError>,
> => {
  QueryHelpers.executeFetchRequest(
    ~endpoint=serverUrl ++ "/query",
    ~method=#POST,
    ~bodyAndSchema=(postQueryBody, QueryTypes.postQueryBodySchema),
    ~responseSchema=ResponseTypes.queryResponseSchema,
    (),
  )
}

let getArchiveHeight = {
  let responseSchema = S.object((. s) => s.field("height", S.int))

  async (~serverUrl): result<int, QueryHelpers.queryError> => {
    await QueryHelpers.executeFetchRequest(
      ~endpoint=serverUrl ++ "/height",
      ~method=#GET,
      ~responseSchema,
      (),
    )
  }
}
