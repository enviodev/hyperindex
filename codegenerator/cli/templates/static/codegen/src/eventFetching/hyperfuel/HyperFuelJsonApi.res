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

  type receiptParams = {
    root_contract_id?: array<Address.t>,
    contract_id?: array<Address.t>,
    receipt_type?: array<Fuel.receiptType>,
  }

  type transactionParams = {
    from?: array<Address.t>,
    @as("to") to_?: array<Address.t>,
    sighash?: array<string>,
  }

  type postQueryBody = {
    @as("from_block") fromBlock: int,
    @as("to_block") toBlockExclusive?: int,
    receipts?: array<receiptParams>,
    transactions?: array<transactionParams>,
    @as("field_selection") fieldSelection: fieldSelection,
    @as("max_num_receipts") maxNumreceipts?: int,
  }
}

module FuelTypes = {
  type block = {
    id?: string,
    @as("da_height") daHeight?: int,
    @as("transactions_count") transactionsCount?: int,
    @as("message_receipt_count") messageReceiptCount?: int,
    @as("transactions_root") transactionsRoot?: string,
    @as("message_receipt_root") messageReceiptRoot?: string,
    height?: int,
    @as("prev_root") prevRoot?: string,
    time?: int,
    @as("application_hash") applicationHash?: string,
  }

  type transaction = {
    @as("block_height") blockHeight?: int,
    id?: string,
    @as("input_asset_ids") inputAssetIds?: array<string>,
    @as("input_contracts") inputContracts?: array<string>,
    @as("input_contract_utxo_id") inputContractUtxoId?: string,
    @as("input_contract_balance_root") inputContractBalanceRoot?: string,
    @as("input_contract_state_root") inputContractStateRoot?: string,
    @as("input_contract_tx_pointer_tx_index") inputContractTxPointerTxIndex?: int,
    @as("input_contract") inputContract?: string,
    @as("gas_price") gasPrice?: int,
    @as("gas_limit") gasLimit?: int,
    maturity?: int,
    @as("mint_amount") mintAmount?: int,
    @as("mint_asset_id") mintAssetId?: string,
    @as("tx_pointer_block_height") txPointerBlockHeight?: int,
    @as("tx_pointer_tx_index") txPointerTxIndex?: int,
    @as("tx_type") txType?: int,
    @as("output_contract_input_index") outputContractInputIndex?: int,
    @as("output_contract_balance_root") outputContractBalanceRoot?: string,
    @as("output_contract_state_root") outputContractStateRoot?: string,
    witnesses?: array<string>,
    @as("receipts_root") receiptsRoot?: string,
    status?: int,
    time?: int,
    reason?: string,
    script?: string,
    @as("script_data") scriptData?: string,
    @as("bytecode_witness_index") bytecodeWitnessIndex?: int,
    @as("bytecode_length") bytecodeLength?: int,
    salt?: string,
  }

  type receipt = {
    @as("root_contract_id") rootContractId?: Address.t,
    @as("tx_id") txId?: string,
    @as("tx_status") txStatus?: int,
    @as("block_height") blockHeight?: int,
    pc?: int,
    is?: string,
    to?: string,
    @as("to_address") toAddress?: string,
    amount?: int,
    @as("asset_id") assetId?: string,
    gas?: int,
    param1?: string,
    param2?: string,
    val?: int,
    ptr?: int,
    digest?: string,
    reason?: string,
    ra?: int,
    rb?: int,
    rc?: int,
    rd?: int,
    len?: int,
    @as("receipt_type") receiptType?: Fuel.receiptType,
    result?: string,
    @as("gas_used") gasUsed?: int,
    data?: string,
    sender?: string,
    recipient?: string,
    nonce?: int,
    @as("contract_id") contractId?: Address.t,
    @as("sub_id") subId?: string,
  }

  type input = {
    @as("tx_id") txId?: string,
    @as("block_height") blockHeight?: int,
    @as("input_type") inputType?: int,
    @as("utxo_id") utxoId?: string,
    owner?: string,
    amount?: int,
    @as("asset_id") assetId?: string,
    @as("tx_pointer_block_height") txPointerBlockHeight?: int,
    @as("tx_pointer_tx_index") txPointerTxIndex?: int,
    @as("witness_index") witnessIndex?: int,
    @as("predicate_gas_used") predicateGasUsed?: int,
    predicate?: string,
    @as("predicate_data") predicateData?: string,
    @as("balance_root") balanceRoot?: string,
    @as("state_root") stateRoot?: string,
    contract?: string,
    sender?: string,
    recipient?: string,
    nonce?: int,
    data?: string,
  }

  type output = {
    @as("tx_id") txId?: string,
    @as("block_height") blockHeight?: int,
    @as("output_type") outputType?: int,
    to?: string,
    amount?: int,
    @as("asset_id") assetId?: string,
    @as("input_index") inputIndex?: int,
    @as("balance_root") balanceRoot?: string,
    @as("state_root") stateRoot?: string,
    contract?: string,
  }
}

module ResponseTypes = {
  type fuelData = {
    blocks?: array<FuelTypes.block>,
    transactions?: array<FuelTypes.transaction>,
    receipts?: array<FuelTypes.receipt>,
    inputs?: array<FuelTypes.input>,
    outputs?: array<FuelTypes.output>,
  }

  type queryResponse = {
    data: array<fuelData>,
    @as("archive_height") archiveHeight: int,
    @as("next_block") nextBlock: int,
    @as("total_execution_time") totalTime: int,
  }

  type heightResponse = {height: int}
}

module Query = {
  exception FailedToFetch(exn)
  exception FailedToParseJson(exn)

  type queryError = FailedToFetch(exn) | FailedToParseJson(exn) | Other(exn)

  let executeFetchRequest = async (
    ~endpoint,
    ~method: Fetch.method,
    ~rawBody: option<QueryTypes.postQueryBody>=?,
    (),
  ): result<'b, queryError> => {
    try {
      open Fetch

      let body =
        rawBody->Belt.Option.map(body =>
          body->Js.Json.stringifyAny->Belt.Option.getExn->Body.string
        )

      let res = await fetch(
        endpoint,
        {
          method,
          headers: Headers.fromObject({"Content-type": "application/json"}),
          ?body,
        },
      )->Promise.catch(e => Promise.reject(FailedToFetch(e)))

      let data =
        await res
        ->Response.json
        ->Promise.catch(e => {
          Js.log("unable to decode")
          Js.log(e)
          Promise.reject(FailedToParseJson(e))
        })

      Ok(data->Utils.magic)
    } catch {
    | FailedToFetch(exn) => Error(FailedToFetch(exn))
    | FailedToParseJson(exn) => Error(FailedToParseJson(exn))
    | exn => Error(Other(exn))
    }
  }
}
let executeHyperSyncQuery = (~serverUrl, ~postQueryBody: QueryTypes.postQueryBody): promise<
  result<ResponseTypes.queryResponse, Query.queryError>,
> => {
  Logging.debug({"msg": "Executing HyperSync query", "body": postQueryBody})
  Query.executeFetchRequest(
    ~endpoint=serverUrl ++ "/query",
    ~method=#POST,
    ~rawBody=postQueryBody,
    (),
  )
}

type heightResponse = {height: int}

let getArchiveHeight = async (~serverUrl): result<heightResponse, Query.queryError> => {
  let res = await Query.executeFetchRequest(~endpoint=serverUrl ++ "/height", ~method=#GET, ())
  res
}
