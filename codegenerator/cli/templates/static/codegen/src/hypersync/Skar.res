@spice
type unchecksummedEthAddress = string

module QueryTypes = {
  @spice
  type blockFieldOptions = [
    | #parent_hash
    | #sha3Uncles
    | #miner
    | #state_root
    | #transactions_root
    | #receipts_root
    | #logs_bloom
    | #difficulty
    | #number
    | #gas_limit
    | #gas_used
    | #timestamp
    | #extra_data
    | #mix_hash
    | #nonce
    | #total_difficulty
    | #base_fee_per_gas
    | #size
    | #hash
  ]

  @spice
  type blockFieldSelection = array<blockFieldOptions>

  @spice
  type transactionFieldOptions = [
    | #"type"
    | #nonce
    | #to
    | #gas
    | #value
    | #input
    | #max_priority_fee_per_gas
    | #max_fee_per_gas
    | #y_parity
    | #chain_id
    | #v
    | #r
    | #s
    | #from
    | #block_hash
    | #block_number
    | #index
    | #gas_price
    | #hash
    | #status
  ]

  @spice
  type transactionFieldSelection = array<transactionFieldOptions>

  @spice
  type logFieldOptions = [
    | #address
    | #block_hash
    | #block_number
    | #data
    | #index
    | #removed
    | #topics
    | #transaction_hash
    | #transaction_index
  ]

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
    @spice.key("field_selection") fieldSelection: fieldSelection,
  }

  @spice
  type transactionParams = {
    address?: array<Ethers.ethAddress>,
    sighash?: array<string>,
    @spice.key("field_selection") fieldSelection: fieldSelection,
  }

  @spice
  type postQueryBody = {
    @spice.key("from_block") fromBlock: int,
    @spice.key("to_block") toBlockExclusive?: int,
    logs?: array<logParams>,
    transactions?: array<transactionParams>,
  }
}

module ResponseTypes = {
  @spice
  type blockData = {
    @spice.key("parent_hash") parentHash?: string,
    @spice.key("sha3_uncles") sha3Uncles?: string,
    miner?: unchecksummedEthAddress,
    @spice.key("state_root") stateRoot?: string,
    @spice.key("transactions_root") transactionsRoot?: string,
    @spice.key("receipts_root") receiptsRoot?: string,
    @spice.key("logs_bloom") logsBloom?: string,
    difficulty?: Ethers.BigInt.t,
    number?: int,
    @spice.key("gas_limit") gasLimit?: Ethers.BigInt.t,
    @spice.key("gas_used") gasUsed?: Ethers.BigInt.t,
    timestamp?: Ethers.BigInt.t,
    @spice.key("extra_data") extraData?: string,
    @spice.key("mix_hash") mixHash?: string,
    nonce?: int,
    @spice.key("total_difficulty") totalDifficulty?: Ethers.BigInt.t,
    @spice.key("base_fee_per_gas") baseFeePerGas?: Ethers.BigInt.t,
    size?: Ethers.BigInt.t,
    hash?: string,
  }

  @spice
  type transactionData = {
    @spice.key("type") type_?: int,
    nonce?: int,
    to?: unchecksummedEthAddress,
    gas?: Ethers.BigInt.t,
    value?: Ethers.BigInt.t,
    input?: string,
    @spice.key("max_priority_fee_per_gas") maxPriorityFeePerGas?: Ethers.BigInt.t,
    @spice.key("max_fee_per_gas") maxFeePerGas?: Ethers.BigInt.t,
    chainId?: int,
    v?: string,
    r?: string,
    s?: string,
    from?: unchecksummedEthAddress,
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    index?: int,
    @spice.key("gas_price") gasPrice?: Ethers.BigInt.t,
    hash?: string,
  }

  @spice
  type logData = {
    address?: unchecksummedEthAddress,
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    data?: string,
    index?: int,
    removed?: bool,
    topics?: array<string>,
    @spice.key("transaction_hash") transactionHash?: string,
    @spice.key("transaction_index") transactionIndex?: int,
  }

  @spice
  type data = {
    block?: blockData,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  @spice
  type queryResponse = {
    data: array<array<data>>,
    @spice.key("archive_height") archiveHeight: int,
    @spice.key("next_block") nextBlock: int,
    @spice.key("total_execution_time") totalTime: int,
  }

  @spice
  type heightResponse = {height: int}
}

let executeSkarQuery = (~serverUrl, ~postQueryBody: QueryTypes.postQueryBody): promise<
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

let getArchiveHeight = EthArchive.getArchiveHeight
