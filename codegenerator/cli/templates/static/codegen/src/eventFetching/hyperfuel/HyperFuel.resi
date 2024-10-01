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
type queryError =
  UnexpectedMissingParams(missingParams) | QueryError(HyperFuelJsonApi.Query.queryError)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>
let queryLogsPage: (
  ~serverUrl: string,
  ~fromBlock: int,
  ~toBlock: int,
  ~recieptsSelection: array<HyperFuelClient.QueryTypes.receiptSelection>,
) => promise<queryResponse<logsQueryPage>>

let queryBlockData: (
  ~serverUrl: string,
  ~blockNumber: int,
  ~logger: Pino.t,
) => promise<option<ReorgDetection.blockData>>

let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
