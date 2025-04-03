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
  receipt: Fuel.Receipt.t,
  receiptIndex: int,
  block: block,
}

type blockNumberAndHash = {
  blockNumber: int,
  hash: string,
}

type logsQueryPage = hyperSyncPage<item>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams)

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~serverUrl: string,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~recieptsSelection: array<HyperFuelClient.QueryTypes.receiptSelection>,
  ) => promise<logsQueryPage>
}

let queryBlockData: (
  ~serverUrl: string,
  ~blockNumber: int,
  ~logger: Pino.t,
) => promise<option<ReorgDetection.blockDataWithTimestamp>>

let heightRoute: Rest.route<unit, int>
