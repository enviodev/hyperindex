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

let queryErrorToMsq: queryError => string

type queryResponse<'a> = result<'a, queryError>

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~client: HyperSyncClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~logSelections: array<LogSelection.t>,
    ~fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
    ~nonOptionalBlockFieldNames: array<string>,
    ~nonOptionalTransactionFieldNames: array<string>,
  ) => promise<logsQueryPage>
}

let queryBlockData: (
  ~serverUrl: string,
  ~apiToken: string,
  ~blockNumber: int,
  ~logger: Pino.t,
) => promise<queryResponse<option<ReorgDetection.blockDataWithTimestamp>>>

let queryBlockDataMulti: (
  ~serverUrl: string,
  ~apiToken: string,
  ~blockNumbers: array<int>,
  ~logger: Pino.t,
) => promise<queryResponse<array<ReorgDetection.blockDataWithTimestamp>>>

let mapExn: queryResponse<'a> => result<'a, exn>
