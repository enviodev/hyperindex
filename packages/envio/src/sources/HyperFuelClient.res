type t

type cfg = {
  url: string,
  bearerToken?: string,
}
module QueryTypes = {
  type blockFieldOptions =
    | @as("id") Id
    | @as("height") Height
    | @as("time") Time

  type blockFieldSelection = array<blockFieldOptions>

  type receiptFieldOptions =
    | @as("tx_id") TxId
    | @as("block_height") BlockHeight
    | @as("to_address") ToAddress
    | @as("amount") Amount
    | @as("asset_id") AssetId
    | @as("val") Val
    | @as("rb") Rb
    | @as("receipt_type") ReceiptType
    | @as("receipt_index") ReceiptIndex
    | @as("data") Data
    | @as("root_contract_id") RootContractId
    | @as("sub_id") SubId
    | @as("to") To

  type receiptFieldSelection = array<receiptFieldOptions>

  type fieldSelection = {
    block?: blockFieldSelection,
    receipt?: receiptFieldSelection,
  }

  type receiptSelection = {
    rootContractId?: array<Address.t>,
    receiptType?: array<FuelSDK.receiptType>,
    rb?: array<bigint>,
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
   * Field selection. The user can select which fields they are interested in, requesting less fields will improve
   *  query execution time and reduce the payload size so the user should always use a minimal number of fields.
   */
    fieldSelection: fieldSelection,
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
  blocks: array<FuelTypes.block>,
}

type queryResponseTyped = {
  /** Current height of the source HyperFuel instance */
  archiveHeight?: int,
  /**
   * Next block to query for, the responses are paginated so
   * the caller should continue the query from this block if they
   * didn't get responses up to the to_block they specified in the Query.
   */
  nextBlock: int,
  /** Total time it took the HyperFuel instance to execute the query. */
  totalExecutionTime: int,
  /** Response data */
  data: queryResponseDataTyped,
}

@send
external classNew: (Core.hyperfuelClientCtor, cfg) => t = "new"

let make = (cfg: cfg) => Core.getAddon().hyperfuelClient->classNew(cfg)

@send
external getSelectedData: (t, QueryTypes.query) => promise<queryResponseTyped> = "getSelectedData"

@send
external getHeight: t => promise<int> = "getHeight"
