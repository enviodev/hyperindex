type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  events: array<HyperSyncClient.ResponseTypes.event>,
}

type logsQueryPageItem = {
  log: Ethers.log,
  blockTimestamp: int,
  txOrigin: option<Ethers.ethAddress>,
  txTo: option<Ethers.ethAddress>,
}

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
  ~contractAddressesAndtopics: ContractInterfaceManager.contractAddressesAndTopics,
) => promise<queryResponse<logsQueryPage>>

let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
let queryBlockData: (
  ~serverUrl: string,
  ~blockNumber: int,
) => promise<queryResponse<option<ReorgDetection.blockData>>>

let queryBlockDataMulti: (
  ~serverUrl: string,
  ~blockNumbers: array<int>,
) => promise<queryResponse<array<ReorgDetection.blockData>>>

let mapExn: queryResponse<'a> => result<'a, exn>
let getExn: queryResponse<'a> => 'a
