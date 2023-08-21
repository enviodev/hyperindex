module type S = {
  open HyperSyncTypes
  let queryLogsPage: (
    ~serverUrl: string,
    ~fromBlock: int,
    ~toBlock: int,
    ~addresses: array<Ethers.ethAddress>,
    ~topics: array<array<Ethers.EventFilter.topic>>,
  ) => promise<queryResponse<logsQueryPage>>

  let queryBlockTimestampsPage: (
    ~serverUrl: string,
    ~fromBlock: int,
    ~toBlock: int,
  ) => promise<queryResponse<blockTimestampPage>>

  let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
  let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
}

module MakeHyperSyncFromBuilder = (Builder: HyperSyncTypes.QueryBuilder): S => {
  let queryLogsPage = Builder.LogsQuery.queryLogsPage
  let queryBlockTimestampsPage = Builder.BlockTimestampQuery.queryBlockTimestampsPage
  let getHeightWithRetry = Builder.HeightQuery.getHeightWithRetry
  let pollForHeightGtOrEq = Builder.HeightQuery.pollForHeightGtOrEq
}

module SkarHyperSync = MakeHyperSyncFromBuilder(SkarQueryBuilder)
module EthArchiveHyperSync = MakeHyperSyncFromBuilder(EthArchiveQueryBuilder)
