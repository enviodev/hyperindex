type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  // Page store owning this page's raw blocks (built on the Rust side).
  blockStore: BlockStore.t,
}

type block = {
  id: string,
  time: int,
  height: int,
}

type item = {
  transactionId: string,
  contractId: Address.t,
  receipt: FuelSDK.Receipt.t,
  receiptIndex: int,
  block: block,
}

type logsQueryPage = hyperSyncPage<item>

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~client: HyperFuelClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~recieptsSelection: array<HyperFuelClient.QueryTypes.receiptSelection>,
  ) => promise<logsQueryPage>
}
