type unchecksummedEthAddress = string

type t

type cfg = {
  url: string,
  bearerToken?: string,
  http_req_timeout_millis?: int,
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
    receiptType?: array<Fuel.receiptType>,
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
  /** An object containing information about a transaction. */
  type transaction = {
    /** block the transaction is in. */
    blockHeight: int,
    /** A unique transaction id. */
    id: string,
    /** An array of asset ids used for the transaction inputs. */
    inputAssetIds?: array<string>,
    /** An array of contracts used for the transaction inputs. */
    inputContracts?: array<string>,
    /**
   * A contract used for the transaction input.
   * A unique 32 byte identifier for the UTXO for a contract used for the transaction input.
   */
    inputContractUtxoId?: string,
    /** The root of amount of coins owned by contract before transaction execution for a contract used for the transaction input. */
    inputContractBalanceRoot?: string,
    /** The state root of contract before transaction execution for a contract used for the transaction input. */
    inputContractStateRoot?: string,
    /** A pointer to the TX whose output is being spent for a contract used for the transaction input. */
    inputContractTxPointerBlockHeight?: int,
    /** A pointer to the TX whose output is being spent for a contract used for the transaction input. */
    inputContractTxPointerTxIndex?: int,
    /** The contract id for a contract used for the transaction input. */
    inputContract?: string,
    /** The gas price for the transaction. */
    gasPrice?: bigint,
    /** The gas limit for the transaction. */
    gasLimit?: bigint,
    /** The minimum block height that the transaction can be included at. */
    maturity?: int,
    /** The amount minted in the transaction. */
    mintAmount?: bigint,
    /** The asset ID for coins minted in the transaction. */
    mintAssetId?: string,
    /** The location of the transaction in the block. */
    txPointerBlockHeight?: int,
    txPointerTxIndex?: int,
    /** Script, creating a new contract, or minting new coins */
    txType: int,
    /** The index of the input from a transaction that changed the state of a contract. */
    outputContractInputIndex?: int,
    /** The root of amount of coins owned by contract after transaction execution from a transaction that changed the state of a contract. */
    outputContractBalanceRoot?: string,
    /** The state root of contract after transaction execution from a transaction that changed the state of a contract. */
    outputContractStateRoot?: string,
    /** An array of witnesses. */
    witnesses?: string,
    /** The root of the receipts. */
    receiptsRoot?: string,
    /** The status type of the transaction. */
    status: int,
    /** for SubmittedStatus, SuccessStatus, and FailureStatus, the time a transaction was submitted, successful, or failed */
    time: int,
    /**
   * for SuccessStatus, the state of the program execution
   * for SqueezedOutStatus & FailureStatus, the reason the transaction was squeezed out or failed
   */
    reason?: string,
    /** The script to execute. */
    script?: string,
    /** The script input parameters. */
    scriptData?: string,
    /** The witness index of contract bytecode. */
    bytecodeWitnessIndex?: int,
    /** The length of the transaction bytecode. */
    bytecodeLength?: int,
    /** The salt value for the transaction. */
    salt?: string,
  }
  /** An object representing all possible types of receipts. */
  type receipt = {
    /** Index of the receipt in the block */
    receiptIndex: int,
    /** Contract that produced the receipt */
    rootContractId?: Address.t,
    /** transaction that this receipt originated from */
    txId: string,
    /** The status type of the transaction this receipt originated from */
    txStatus: int,
    /** block that the receipt originated in */
    blockHeight: int,
    /** The value of the program counter register $pc, which is the memory address of the current instruction. */
    pc?: int,
    /** The value of register $is, which is the pointer to the start of the currently-executing code. */
    is?: int,
    /** The recipient contract */
    to?: string,
    /** The recipient address */
    toAddress?: string,
    /** The amount of coins transferred. */
    amount?: bigint,
    /** The asset id of the coins transferred. */
    assetId?: string,
    /** The gas used for the transaction. */
    gas?: int,
    /** The first parameter for a CALL receipt type, holds the function selector. */
    param1?: bigint,
    /** The second parameter for a CALL receipt type, typically used for the user-specified input to the ABI function being selected. */
    param2?: bigint,
    /** The value of registers at the end of execution, used for debugging. */
    val?: bigint,
    /** The value of the pointer register, used for debugging. */
    ptr?: bigint,
    /** A 32-byte String of MEM[$rC, $rD]. The syntax MEM[x, y] means the memory range starting at byte x, of length y bytes. */
    digest?: string,
    /** The decimal string representation of an 8-bit unsigned integer for the panic reason. Only returned if the receipt type is PANIC. */
    reason?: int,
    /** The value of register $rA. */
    ra?: bigint,
    /** The value of register $rB. */
    rb?: bigint,
    /** The value of register $rC. */
    rc?: bigint,
    /** The value of register $rD. */
    rd?: bigint,
    /** The length of the receipt. */
    len?: bigint,
    /** The type of receipt. */
    receiptType: Fuel.receiptType,
    /** 0 if script exited successfully, any otherwise. */
    result?: int,
    /** The amount of gas consumed by the script. */
    gasUsed?: int,
    /** The receipt data. */
    data?: string,
    /** The address of the message sender. */
    sender?: string,
    /** The address of the message recipient. */
    recipient?: string,
    /** The nonce value for a message. */
    nonce?: string,
    /** Current context if in an internal context. null otherwise */
    contractId?: Address.t,
    /** The sub id. */
    subId?: string,
  }

  // Unused - in indexer currently
  type input = {
    txId: string,
    blockHeight: int,
    inputType: int,
    utxoId?: string,
    owner?: string,
    amount?: bigint,
    assetId?: string,
    txPointerBlockHeight?: int,
    txPointerTxIndex?: int,
    witnessIndex?: int,
    predicateGasUsed?: int,
    predicate?: string,
    predicateData?: string,
    balanceRoot?: string,
    stateRoot?: string,
    contract?: string,
    sender?: string,
    recipient?: string,
    nonce?: string,
    data?: string,
  }

  // Unused in indexer currently
  type output = {
    txId: string,
    blockHeight: int,
    outputType: int,
    to?: string,
    amount?: bigint,
    assetId?: string,
    inputIndex?: int,
    balanceRoot?: string,
    stateRoot?: string,
    contract?: string,
  }

  // Unused in indexer currently
  /** The block header contains metadata about a certain block. */
  type block = {
    /** String of the header */
    id: string,
    /** The block height for the data availability layer up to which (inclusive) input messages are processed. */
    daHeight: int,
    consensusParametersVersion: int,
    stateTransitionBytecodeVersion: int,
    /** The number of transactions in the block. */
    transactionsCount: string,
    /** The number of receipt messages in the block. */
    messageReceiptCount: string,
    /** The merkle root of the transactions in the block. */
    transactionsRoot: string,
    messageOutboxRoot: string,
    eventInboxRoot: string,
    /** The block height. */
    height: int,
    /** The merkle root of all previous consensus header Stringes (not including this block). */
    prevRoot: string,
    /** The timestamp for the block. */
    time: int,
    /** The String of the serialized application header for this block. */
    applicationHash: string,
  }
}

type queryResponseDataTyped = {
  transactions: array<FuelTypes.transaction>,
  receipts: array<FuelTypes.receipt>,
  blocks: option<array<FuelTypes.block>>,
  inputs: array<FuelTypes.input>,
  outputs: array<FuelTypes.output>,
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

@module("@envio-dev/hyperfuel-client") @scope("HyperfuelClient")
external make: cfg => t = "new"
let make = (cfg: cfg) => {
  make({...cfg, bearerToken: "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"})
}

@send
external getSelectedData: (t, QueryTypes.query) => promise<queryResponseTyped> = "getSelectedData"
