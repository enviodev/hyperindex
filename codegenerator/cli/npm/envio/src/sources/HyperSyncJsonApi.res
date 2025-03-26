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

  let blockFieldOptionsSchema = S.enum([
    Number,
    Hash,
    ParentHash,
    Nonce,
    Sha3Uncles,
    LogsBloom,
    TransactionsRoot,
    StateRoot,
    ReceiptsRoot,
    Miner,
    Difficulty,
    TotalDifficulty,
    ExtraData,
    Size,
    GasLimit,
    GasUsed,
    Timestamp,
    Uncles,
    BaseFeePerGas,
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

  let transactionFieldOptionsSchema = S.enum([
    BlockHash,
    BlockNumber,
    From,
    Gas,
    GasPrice,
    Hash,
    Input,
    Nonce,
    To,
    TransactionIndex,
    Value,
    V,
    R,
    S,
    MaxPriorityFeePerGas,
    MaxFeePerGas,
    ChainId,
    CumulativeGasUsed,
    EffectiveGasPrice,
    GasUsed,
    ContractAddress,
    LogsBloom,
    Type,
    Root,
    Status,
    Sighash,
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

  let logFieldOptionsSchema = S.enum([
    Removed,
    LogIndex,
    TransactionIndex,
    TransactionHash,
    BlockHash,
    BlockNumber,
    Address,
    Data,
    Topic0,
    Topic1,
    Topic2,
    Topic3,
  ])

  type logFieldSelection = array<logFieldOptions>

  let logFieldSelectionSchema = S.array(logFieldOptionsSchema)

  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  let fieldSelectionSchema = S.object(s => {
    block: ?s.field("block", S.option(blockFieldSelectionSchema)),
    transaction: ?s.field("transaction", S.option(transactionFieldSelectionSchema)),
    log: ?s.field("log", S.option(logFieldSelectionSchema)),
  })

  type logParams = {
    address?: array<Address.t>,
    topics: array<array<EvmTypes.Hex.t>>,
  }

  let logParamsSchema = S.object(s => {
    address: ?s.field("address", S.option(S.array(Address.schema))),
    topics: s.field("topics", S.array(S.array(EvmTypes.Hex.schema))),
  })

  type transactionParams = {
    from?: array<Address.t>,
    to?: array<Address.t>,
    sighash?: array<string>,
  }

  let transactionParamsSchema = S.object(s => {
    from: ?s.field("from", S.option(S.array(Address.schema))),
    to: ?s.field("to", S.option(S.array(Address.schema))),
    sighash: ?s.field("sighash", S.option(S.array(S.string))),
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

  let postQueryBodySchema = S.object(s => {
    fromBlock: s.field("from_block", S.int),
    toBlockExclusive: ?s.field("to_block", S.option(S.int)),
    logs: ?s.field("logs", S.option(S.array(logParamsSchema))),
    transactions: ?s.field("transactions", S.option(S.array(transactionParamsSchema))),
    fieldSelection: s.field("field_selection", fieldSelectionSchema),
    maxNumLogs: ?s.field("max_num_logs", S.option(S.int)),
    includeAllBlocks: ?s.field("include_all_blocks", S.option(S.bool)),
  })
}

module ResponseTypes = {
  type blockData = {
    number?: int,
    hash?: string,
    parentHash?: string,
    nonce?: option<int>,
    sha3Uncles?: string,
    logsBloom?: string,
    transactionsRoot?: string,
    stateRoot?: string,
    receiptsRoot?: string,
    miner?: unchecksummedEthAddress,
    difficulty?: option<bigint>,
    totalDifficulty?: option<bigint>,
    extraData?: string,
    size?: bigint,
    gasLimit?: bigint,
    gasUsed?: bigint,
    timestamp?: bigint,
    uncles?: option<string>,
    baseFeePerGas?: option<bigint>,
  }

  let blockDataSchema = S.object(s => {
    number: ?s.field("number", S.option(S.int)),
    hash: ?s.field("hash", S.option(S.string)),
    parentHash: ?s.field("parent_hash", S.option(S.string)),
    nonce: ?s.field("nonce", S.option(S.null(S.int))),
    sha3Uncles: ?s.field("sha3_uncles", S.option(S.string)),
    logsBloom: ?s.field("logs_bloom", S.option(S.string)),
    transactionsRoot: ?s.field("transactions_root", S.option(S.string)),
    stateRoot: ?s.field("state_root", S.option(S.string)),
    receiptsRoot: ?s.field("receipts_root", S.option(S.string)),
    miner: ?s.field("miner", S.option(S.string)),
    difficulty: ?s.field("difficulty", S.option(S.null(BigInt.schema))),
    totalDifficulty: ?s.field("total_difficulty", S.option(S.null(BigInt.schema))),
    extraData: ?s.field("extra_data", S.option(S.string)),
    size: ?s.field("size", S.option(BigInt.schema)),
    gasLimit: ?s.field("gas_limit", S.option(BigInt.schema)),
    gasUsed: ?s.field("gas_used", S.option(BigInt.schema)),
    timestamp: ?s.field("timestamp", S.option(BigInt.schema)),
    uncles: ?s.field("unclus", S.option(S.null(S.string))),
    baseFeePerGas: ?s.field("base_fee_per_gas", S.option(S.null(BigInt.schema))),
  })

  type transactionData = {
    blockHash?: string,
    blockNumber?: int,
    from?: option<unchecksummedEthAddress>,
    gas?: bigint,
    gasPrice?: option<bigint>,
    hash?: string,
    input?: string,
    nonce?: int,
    to?: option<unchecksummedEthAddress>,
    transactionIndex?: int,
    value?: bigint,
    v?: option<string>,
    r?: option<string>,
    s?: option<string>,
    maxPriorityFeePerGas?: option<bigint>,
    maxFeePerGas?: option<bigint>,
    chainId?: option<int>,
    cumulativeGasUsed?: bigint,
    effectiveGasPrice?: bigint,
    gasUsed?: bigint,
    contractAddress?: option<unchecksummedEthAddress>,
    logsBoom?: string,
    type_?: option<int>,
    root?: option<string>,
    status?: option<int>,
    sighash?: option<string>,
  }

  let transactionDataSchema = S.object(s => {
    blockHash: ?s.field("block_hash", S.option(S.string)),
    blockNumber: ?s.field("block_number", S.option(S.int)),
    from: ?s.field("from", S.option(S.null(S.string))),
    gas: ?s.field("gas", S.option(BigInt.schema)),
    gasPrice: ?s.field("gas_price", S.option(S.null(BigInt.schema))),
    hash: ?s.field("hash", S.option(S.string)),
    input: ?s.field("input", S.option(S.string)),
    nonce: ?s.field("nonce", S.option(S.int)),
    to: ?s.field("to", S.option(S.null(S.string))),
    transactionIndex: ?s.field("transaction_index", S.option(S.int)),
    value: ?s.field("value", S.option(BigInt.schema)),
    v: ?s.field("v", S.option(S.null(S.string))),
    r: ?s.field("r", S.option(S.null(S.string))),
    s: ?s.field("s", S.option(S.null(S.string))),
    maxPriorityFeePerGas: ?s.field("max_priority_fee_per_gas", S.option(S.null(BigInt.schema))),
    maxFeePerGas: ?s.field("max_fee_per_gas", S.option(S.null(BigInt.schema))),
    chainId: ?s.field("chain_id", S.option(S.null(S.int))),
    cumulativeGasUsed: ?s.field("cumulative_gas_used", S.option(BigInt.schema)),
    effectiveGasPrice: ?s.field("effective_gas_price", S.option(BigInt.schema)),
    gasUsed: ?s.field("gas_used", S.option(BigInt.schema)),
    contractAddress: ?s.field("contract_address", S.option(S.null(S.string))),
    logsBoom: ?s.field("logs_bloom", S.option(S.string)),
    type_: ?s.field("type", S.option(S.null(S.int))),
    root: ?s.field("root", S.option(S.null(S.string))),
    status: ?s.field("status", S.option(S.null(S.int))),
    sighash: ?s.field("sighash", S.option(S.null(S.string))),
  })

  type logData = {
    removed?: option<bool>,
    index?: int,
    transactionIndex?: int,
    transactionHash?: string,
    blockHash?: string,
    blockNumber?: int,
    address?: unchecksummedEthAddress,
    data?: string,
    topic0?: option<EvmTypes.Hex.t>,
    topic1?: option<EvmTypes.Hex.t>,
    topic2?: option<EvmTypes.Hex.t>,
    topic3?: option<EvmTypes.Hex.t>,
  }

  let logDataSchema = S.object(s => {
    removed: ?s.field("removed", S.option(S.null(S.bool))),
    index: ?s.field("log_index", S.option(S.int)),
    transactionIndex: ?s.field("transaction_index", S.option(S.int)),
    transactionHash: ?s.field("transaction_hash", S.option(S.string)),
    blockHash: ?s.field("block_hash", S.option(S.string)),
    blockNumber: ?s.field("block_number", S.option(S.int)),
    address: ?s.field("address", S.option(S.string)),
    data: ?s.field("data", S.option(S.string)),
    topic0: ?s.field("topic0", S.option(S.null(EvmTypes.Hex.schema))),
    topic1: ?s.field("topic1", S.option(S.null(EvmTypes.Hex.schema))),
    topic2: ?s.field("topic2", S.option(S.null(EvmTypes.Hex.schema))),
    topic3: ?s.field("topic3", S.option(S.null(EvmTypes.Hex.schema))),
  })

  type data = {
    blocks?: array<blockData>,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  let dataSchema = S.object(s => {
    blocks: ?s.field("blocks", S.array(blockDataSchema)->S.option),
    transactions: ?s.field("transactions", S.array(transactionDataSchema)->S.option),
    logs: ?s.field("logs", S.array(logDataSchema)->S.option),
  })

  type queryResponse = {
    data: array<data>,
    archiveHeight: int,
    nextBlock: int,
    totalTime: int,
  }

  let queryResponseSchema = S.object(s => {
    data: s.field("data", S.array(dataSchema)),
    archiveHeight: s.field("archive_height", S.int),
    nextBlock: s.field("next_block", S.int),
    totalTime: s.field("total_execution_time", S.int),
  })
}

let queryRoute = Rest.route(() => {
  path: "/query",
  method: Post,
  input: s =>
    {
      "query": s.body(QueryTypes.postQueryBodySchema),
      "token": s.auth(Bearer),
    },
  responses: [s => s.data(ResponseTypes.queryResponseSchema)],
})

let heightRoute = Rest.route(() => {
  path: "/height",
  method: Get,
  input: s => s.auth(Bearer),
  responses: [s => s.field("height", S.int)],
})
