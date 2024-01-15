@spice
type unchecksummedEthAddress = string

module QueryTypes = {
  @spice
  type blockFieldOptions =
    | @spice.as("number") Number
    | @spice.as("hash") Hash
    | @spice.as("parent_hash") ParentHash
    | @spice.as("nonce") Nonce
    | @spice.as("sha3_uncles") Sha3Uncles
    | @spice.as("logs_bloom") LogsBloom
    | @spice.as("transactions_root") TransactionsRoot
    | @spice.as("state_root") StateRoot
    | @spice.as("receipts_root") ReceiptsRoot
    | @spice.as("miner") Miner
    | @spice.as("difficulty") Difficulty
    | @spice.as("total_difficulty") TotalDifficulty
    | @spice.as("extra_data") ExtraData
    | @spice.as("size") Size
    | @spice.as("gas_limit") GasLimit
    | @spice.as("gas_used") GasUsed
    | @spice.as("timestamp") Timestamp
    | @spice.as("uncles") Uncles
    | @spice.as("base_fee_per_gas") BaseFeePerGas

  @spice
  type blockFieldSelection = array<blockFieldOptions>

  @spice
  type transactionFieldOptions =
    | @spice.as("block_hash") BlockHash
    | @spice.as("block_number") BlockNumber
    | @spice.as("from") From
    | @spice.as("gas") Gas
    | @spice.as("gas_price") GasPrice
    | @spice.as("hash") Hash
    | @spice.as("input") Input
    | @spice.as("nonce") Nonce
    | @spice.as("to") To
    | @spice.as("transaction_index") TransactionIndex
    | @spice.as("value") Value
    | @spice.as("v") V
    | @spice.as("r") R
    | @spice.as("s") S
    | @spice.as("max_priority_fee_per_gas") MaxPriorityFeePerGas
    | @spice.as("max_fee_per_gas") MaxFeePerGas
    | @spice.as("chain_id") ChainId
    | @spice.as("cumulative_gas_used") CumulativeGasUsed
    | @spice.as("effective_gas_price") EffectiveGasPrice
    | @spice.as("gas_used") GasUsed
    | @spice.as("contract_address") ContractAddress
    | @spice.as("logs_bloom") LogsBloom
    | @spice.as("type") Type
    | @spice.as("root") Root
    | @spice.as("status") Status
    | @spice.as("sighash") Sighash

  @spice
  type transactionFieldSelection = array<transactionFieldOptions>

  @spice
  type logFieldOptions =
    | @spice.as("removed") Removed
    | @spice.as("log_index") LogIndex
    | @spice.as("transaction_index") TransactionIndex
    | @spice.as("transaction_hash") TransactionHash
    | @spice.as("block_hash") BlockHash
    | @spice.as("block_number") BlockNumber
    | @spice.as("address") Address
    | @spice.as("data") Data
    | @spice.as("topic0") Topic0
    | @spice.as("topic1") Topic1
    | @spice.as("topic2") Topic2
    | @spice.as("topic3") Topic3

  @spice
  type logFieldSelection = array<logFieldOptions>

  @spice
  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  @spice
  type logParams = {
    address?: array<Ethers.ethAddress>,
    topics: array<array<Ethers.EventFilter.topic>>,
  }

  @spice
  type transactionParams = {
    from?: array<Ethers.ethAddress>,
    @spice.key("to")
    to_?: array<Ethers.ethAddress>,
    sighash?: array<string>,
  }

  @spice
  type postQueryBody = {
    @spice.key("from_block") fromBlock: int,
    @spice.key("to_block") toBlockExclusive?: int,
    logs?: array<logParams>,
    transactions?: array<transactionParams>,
    @spice.key("field_selection") fieldSelection: fieldSelection,
    @spice.key("max_num_logs") maxNumLogs?: int,
    @spice.key("include_all_blocks") includeAllBlocks?: bool,
  }
}

module ResponseTypes = {
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type blockData = {
    number?: int,
    hash?: string,
    @spice.key("parent_hash") parentHash?: string,
    nonce?: int, //nullable
    @spice.key("sha3_uncles") sha3Uncles?: string,
    @spice.key("logs_bloom") logsBloom?: string,
    @spice.key("transactions_root") transactionsRoot?: string,
    @spice.key("state_root") stateRoot?: string,
    @spice.key("receipts_root") receiptsRoot?: string,
    miner?: unchecksummedEthAddress,
    difficulty?: Ethers.BigInt.t, //nullable
    @spice.key("total_difficulty") totalDifficulty?: Ethers.BigInt.t, //nullable
    @spice.key("extra_data") extraData?: string,
    size?: Ethers.BigInt.t,
    @spice.key("gas_limit") gasLimit?: Ethers.BigInt.t,
    @spice.key("gas_used") gasUsed?: Ethers.BigInt.t,
    timestamp?: Ethers.BigInt.t,
    @spice.key("unclus") uncles?: string, //nullable
    @spice.key("base_fee_per_gas") baseFeePerGas?: Ethers.BigInt.t, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type transactionData = {
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    from?: unchecksummedEthAddress, //nullable
    gas?: Ethers.BigInt.t,
    @spice.key("gas_price") gasPrice?: Ethers.BigInt.t, //nullable
    hash?: string,
    input?: string,
    nonce?: int,
    to?: unchecksummedEthAddress, //nullable
    @spice.key("transaction_index") transactionIndex?: int,
    value?: Ethers.BigInt.t,
    v?: string, //nullable
    r?: string, //nullable
    s?: string, //nullable
    @spice.key("max_priority_fee_per_gas") maxPriorityFeePerGas?: Ethers.BigInt.t, //nullable
    @spice.key("max_fee_per_gas") maxFeePerGas?: Ethers.BigInt.t, //nullable
    @spice.key("chain_id") chainId?: int, //nullable
    @spice.key("cumulative_gas_used") cumulativeGasUsed?: Ethers.BigInt.t,
    @spice.key("effective_gas_price") effectiveGasPrice?: Ethers.BigInt.t,
    @spice.key("gas_used") gasUsed?: Ethers.BigInt.t,
    @spice.key("contract_address") contractAddress?: unchecksummedEthAddress, //nullable
    @spice.key("logs_bloom") logsBoom?: string,
    @spice.key("type") type_?: int, //nullable
    @spice.key("root") root?: string, //nullable
    @spice.key("status") status?: int, //nullable
    @spice.key("sighash") sighash?: string, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type logData = {
    removed?: bool, //nullable
    @spice.key("log_index") index?: int,
    @spice.key("transaction_index") transactionIndex?: int,
    @spice.key("transaction_hash") transactionHash?: string,
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    address?: unchecksummedEthAddress,
    data?: string,
    topic0?: Ethers.EventFilter.topic, //nullable
    topic1?: Ethers.EventFilter.topic, //nullable
    topic2?: Ethers.EventFilter.topic, //nullable
    topic3?: Ethers.EventFilter.topic, //nullable
  }

  @spice
  type data = {
    blocks?: array<blockData>,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  @spice
  type queryResponse = {
    data: array<data>,
    @spice.key("archive_height") archiveHeight: int,
    @spice.key("next_block") nextBlock: int,
    @spice.key("total_execution_time") totalTime: int,
  }

  @spice
  type heightResponse = {height: int}
}

let executeHyperSyncQuery = (~serverUrl, ~postQueryBody: QueryTypes.postQueryBody): promise<
  result<ResponseTypes.queryResponse, QueryHelpers.queryError>,
> => {
  QueryHelpers.executeFetchRequest(
    ~endpoint=serverUrl ++ "/query",
    ~method=#POST,
    ~bodyAndEncoder=(postQueryBody, QueryTypes.postQueryBody_encode),
    ~responseDecoder=ResponseTypes.queryResponse_decode,
    (),
  )
}

let getArchiveHeight = async (~serverUrl): result<int, QueryHelpers.queryError> => {
  let res = await QueryHelpers.executeFetchRequest(
    ~endpoint=serverUrl ++ "/height",
    ~method=#GET,
    ~responseDecoder=ResponseTypes.heightResponse_decode,
    (),
  )

  res->Belt.Result.map(res => res.height)
}
