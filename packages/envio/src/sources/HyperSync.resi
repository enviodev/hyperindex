type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
}

module Log: {
  type t = HyperSyncClient.EventItems.Log.t = {
    logIndex: int,
    address: Address.t,
    data: string,
    topics: array<EvmTypes.Hex.t>,
  }
}

type logsQueryPageItem = {
  log: Log.t,
  block: HyperSyncClient.ResponseTypes.block,
  transaction: Internal.eventTransaction,
  params: Nullable.t<Internal.eventParams>,
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
  ~client: HyperSyncClient.t,
  ~blockNumber: int,
  ~sourceName: string,
  ~chainId: int,
  ~logger: Pino.t,
) => promise<queryResponse<option<ReorgDetection.blockDataWithTimestamp>>>

let queryBlockDataMulti: (
  ~client: HyperSyncClient.t,
  ~blockNumbers: array<int>,
  ~sourceName: string,
  ~chainId: int,
  ~logger: Pino.t,
) => promise<queryResponse<array<ReorgDetection.blockDataWithTimestamp>>>

let mapExn: queryResponse<'a> => result<'a, exn>
