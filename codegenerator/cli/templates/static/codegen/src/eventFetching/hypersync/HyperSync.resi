type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  events: array<HyperSyncClient.ResponseTypes.event>,
}

type logsQueryPageItem = {
  log: Ethers.log,
  blockTimestamp: int,
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
type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams) | QueryError(QueryHelpers.queryError)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>
let queryLogsPage: (
  ~serverUrl: string,
  ~fromBlock: int,
  ~toBlock: int,
  ~contractAddressesAndtopics: ContractInterfaceManager.contractAdressesAndTopics,
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
