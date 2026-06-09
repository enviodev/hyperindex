type t

type cfg = {
  url: string,
  bearerToken?: string,
  httpReqTimeoutMillis?: int,
}
module QueryTypes = {
  type blockFieldOptions =
    | @as("id") Id
    | @as("da_height") DaHeight
    | @as("transactions_count") TransactionsCount
    | @as("message_receipt_count") MessageReceiptCount
    | @as("transactions_root") TransactionsRoot
    | @as("message_receipt_root") MessageReceiptRoot
    | @as("height") Height
    | @as("prev_root") PrevRoot
    | @as("time") Time
    | @as("application_hash") ApplicationHash

  type blockFieldSelection = array<blockFieldOptions>

  type transactionFieldOptions =
    | @as("id") Id
    | @as("block_height") BlockHeight
    | @as("input_asset_ids") InputAssetIds
    | @as("input_contracts") InputContracts
    | @as("input_contract_utxo_id") InputContractUtxoId
    | @as("input_contract_balance_root") InputContractBalanceRoot
    | @as("input_contract_state_root") InputContractStateRoot
    | @as("input_contract_tx_pointer_block_height") InputContractTxPointerBlockHeight
    | @as("input_contract_tx_pointer_tx_index") InputContractTxPointerTxIndex
    | @as("input_contract") InputContract
    | @as("gas_price") GasPrice
    | @as("gas_limit") GasLimit
    | @as("maturity") Maturity
    | @as("mint_amount") MintAmount
    | @as("mint_asset_id") MintAssetId
    | @as("tx_pointer_block_height") TxPointerBlockHeight
    | @as("tx_pointer_tx_index") TxPointerTxIndex
    | @as("tx_type") TxType
    | @as("output_contract_input_index") OutputContractInputIndex
    | @as("output_contract_balance_root") OutputContractBalanceRoot
    | @as("output_contract_state_root") OutputContractStateRoot
    | @as("witnesses") Witnesses
    | @as("receipts_root") ReceiptsRoot
    | @as("status") Status
    | @as("time") Time
    | @as("reason") Reason
    | @as("script") Script
    | @as("script_data") ScriptData
    | @as("bytecode_witness_index") BytecodeWitnessIndex
    | @as("bytecode_length") BytecodeLength
    | @as("salt") Salt

  type transactionFieldSelection = array<transactionFieldOptions>

  type receiptFieldOptions =
    | @as("tx_id") TxId
    | @as("tx_status") TxStatus
    | @as("block_height") BlockHeight
    | @as("pc") Pc
    | @as("is") Is
    | @as("to") To
    | @as("to_address") ToAddress
    | @as("amount") Amount
    | @as("asset_id") AssetId
    | @as("gas") Gas
    | @as("param1") Param1
    | @as("param2") Param2
    | @as("val") Val
    | @as("ptr") Ptr
    | @as("digest") Digest
    | @as("reason") Reason
    | @as("ra") Ra
    | @as("rb") Rb
    | @as("rc") Rc
    | @as("rd") Rd
    | @as("len") Len
    | @as("receipt_type") ReceiptType
    | @as("receipt_index") ReceiptIndex
    | @as("result") Result
    | @as("gas_used") GasUsed
    | @as("data") Data
    | @as("sender") Sender
    | @as("recipient") Recipient
    | @as("nonce") Nonce
    | @as("contract_id") ContractId
    | @as("root_contract_id") RootContractId
    | @as("sub_id") SubId

  type receiptFieldSelection = array<receiptFieldOptions>

  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    receipt?: receiptFieldSelection,
  }

  type inputSelection
  type outputSelection

  type receiptSelection = {
    rootContractId?: array<Address.t>,
    toAddress?: array<string>,
    assetId?: array<string>,
    receiptType?: array<FuelSDK.receiptType>,
    sender?: array<string>,
    recipient?: array<string>,
    contractId?: array<Address.t>,
    ra?: array<bigint>,
    rb?: array<bigint>,
    rc?: array<bigint>,
    rd?: array<bigint>,
    txStatus?: array<int>,
  }

  type query = {
    /** The block to start the query from */
    fromBlock: int,
    /**
   * The block to end the query at. If not specified, the query will go until the
   *  end of data. Exclusive, the returned range will be [from_block..to_block).
   *
   * The query will return before it reaches this target block if it hits the time limit
   *  configured on the server. The user should continue their query by putting the
   *  next_block field in the response into from_block field of their next query. This implements
   *  pagination.
   */
    @as("toBlock")
    toBlockExclusive?: int,
    /**
   * List of receipt selections, the query will return receipts that match any of these selections and
   *  it will return receipts that are related to the returned objects.
   */
    receipts?: array<receiptSelection>,
    /**
   * List of input selections, the query will return inputs that match any of these selections and
   *  it will return inputs that are related to the returned objects.
   */
    inputs?: array<inputSelection>,
    /**
   * List of output selections, the query will return outputs that match any of these selections and
   *  it will return outputs that are related to the returned objects.
   */
    outputs?: array<outputSelection>,
    /**
   * Whether to include all blocks regardless of if they are related to a returned transaction or log. Normally
   *  the server will return only the blocks that are related to the transaction or logs in the response. But if this
   *  is set to true, the server will return data for all blocks in the requested range [from_block, to_block).
   */
    includeAllBlocks?: bool,
    /**
   * Field selection. The user can select which fields they are interested in, requesting less fields will improve
   *  query execution time and reduce the payload size so the user should always use a minimal number of fields.
   */
    fieldSelection: fieldSelection,
    /**
   * Maximum number of blocks that should be returned, the server might return more blocks than this number but
   *  it won't overshoot by too much.
   */
    maxNumBlocks?: int,
    /**
   * Maximum number of transactions that should be returned, the server might return more transactions than this number but
   *  it won't overshoot by too much.
   */
    maxNumTransactions?: int,
  }
}

module FuelTypes = {
  type receipt = {
    receiptIndex: int,
    rootContractId?: Address.t,
    txId: string,
    blockHeight: int,
    receiptType: FuelSDK.receiptType,
    data?: string,
    rb?: bigint,
    val?: bigint,
    subId?: string,
    amount?: bigint,
    assetId?: string,
    to?: string,
    toAddress?: string,
  }

  type block = {
    id: string,
    height: int,
    time: int,
  }
}

type queryResponseDataTyped = {
  receipts: array<FuelTypes.receipt>,
  blocks: option<array<FuelTypes.block>>,
}

type queryResponseTyped = {
  /** Current height of the source hypersync instance */
  archiveHeight?: int,
  /**
   * Next block to query for, the responses are paginated so
   * the caller should continue the query from this block if they
   * didn't get responses up to the to_block they specified in the Query.
   */
  nextBlock: int,
  /** Total time it took the hypersync instance to execute the query. */
  totalExecutionTime: int,
  /** Response data */
  data: queryResponseDataTyped,
}

@send
external classNew: (Core.hyperfuelClientCtor, cfg) => t = "new"

let make = (cfg: cfg) =>
  Core.getAddon().hyperfuelClient->classNew({
    ...cfg,
    bearerToken: "3dc856dd-b0ea-494f-b27e-017b8b6b7e07",
  })

@send
external getSelectedData: (t, QueryTypes.query) => promise<queryResponseTyped> = "getSelectedData"
