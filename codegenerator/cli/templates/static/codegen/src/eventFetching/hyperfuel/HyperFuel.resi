type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

type block = {
  hash: string,
  timestamp: int,
  blockNumber: int,
}

type item = {
  transactionId: string,
  contractId: Fuel.fuelAddress,
  receipt: Fuel.Receipt.t,
  receiptType: Fuel.receiptType,
  receiptIndex: int,
  block: block,
  txOrigin: option<Ethers.ethAddress>,
}

type blockNumberAndTimestamp = {
  timestamp: int,
  blockNumber: int,
}

type blockNumberAndHash = {
  blockNumber: int,
  hash: string,
}

type blockTimestampPage = hyperSyncPage<blockNumberAndTimestamp>
type logsQueryPage = hyperSyncPage<item>

type contractReceiptQuery = {
  addresses: array<Fuel.fuelAddress>,
  logIds: array<string>,
}

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams) | QueryError(exn)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>
let queryLogsPage: (
  ~serverUrl: string,
  ~fromBlock: int,
  ~toBlock: int,
  ~contractsReceiptQuery: array<contractReceiptQuery>,
) => promise<queryResponse<logsQueryPage>>

let queryBlockTimestampsPage: (
  ~serverUrl: string,
  ~fromBlock: int,
  ~toBlock: int,
) => promise<queryResponse<blockTimestampPage>>

let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
let queryBlockHashes: (
  ~serverUrl: string,
  ~blockNumbers: array<int>,
) => promise<queryResponse<array<blockNumberAndHash>>>
