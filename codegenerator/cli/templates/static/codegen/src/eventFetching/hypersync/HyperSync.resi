type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  events: array<HyperSyncClient.ResponseTypes.event>,
}

module Log: {
  type t = {
    address: Address.t,
    data: string,
    topics: array<EvmTypes.Hex.t>,
    logIndex: int,
  }
}

type logsQueryPageItem = {
  log: Log.t,
  block: Internal.eventBlock,
  transaction: Internal.eventTransaction,
}

type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}

type queryError = UnexpectedMissingParams(missingParams)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>
let queryLogsPage: (
  ~serverUrl: string,
  ~fromBlock: int,
  ~toBlock: option<int>,
  ~logSelections: array<LogSelection.t>,
  ~fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
  ~nonOptionalBlockFieldNames: array<string>,
  ~nonOptionalTransactionFieldNames: array<string>,
) => promise<queryResponse<logsQueryPage>>

let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
let queryBlockData: (
  ~serverUrl: string,
  ~blockNumber: int,
  ~logger: Pino.t,
) => promise<queryResponse<option<ReorgDetection.blockData>>>

let queryBlockDataMulti: (
  ~serverUrl: string,
  ~blockNumbers: array<int>,
  ~logger: Pino.t,
) => promise<queryResponse<array<ReorgDetection.blockData>>>

let mapExn: queryResponse<'a> => result<'a, exn>
let getExn: queryResponse<'a> => 'a
