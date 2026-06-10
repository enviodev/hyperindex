type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
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
    ~serverUrl: string,
    ~apiToken: string,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~recieptsSelection: array<HyperFuelClient.QueryTypes.receiptSelection>,
  ) => promise<logsQueryPage>
}

let heightRoute: Rest.route<unit, int>
