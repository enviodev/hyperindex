type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

type logsQueryPageItem = {
  log: Ethers.log,
  blockTimestamp: int,
}

type blockNumberAndTimestamp = {
  timestamp: int,
  blockNumber: int,
}

type blockTimestampPage = hyperSyncPage<blockNumberAndTimestamp>
type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type queryError = UnexpectedMissingParams | QueryError(QueryHelpers.queryError)
type queryResponse<'a> = result<'a, queryError>

module type LogsQuery = {
  let queryLogsPage: (
    ~serverUrl: string,
    ~fromBlock: int,
    ~toBlock: int,
    ~addresses: array<Ethers.ethAddress>,
    ~topics: array<array<Ethers.EventFilter.topic>>,
  ) => promise<queryResponse<logsQueryPage>>
}

module type BlockTimestampQuery = {
  let queryBlockTimestampsPage: (
    ~serverUrl: string,
    ~fromBlock: int,
    ~toBlock: int,
  ) => promise<queryResponse<blockTimestampPage>>
}

module type HeightQuery = {
  let getHeightWithRetry: (~serverUrl: string, ~logger: Pino.t) => promise<int>
  let pollForHeightGtOrEq: (~serverUrl: string, ~blockNumber: int, ~logger: Pino.t) => promise<int>
}

module type QueryBuilder = {
  module LogsQuery: LogsQuery
  module BlockTimestampQuery: BlockTimestampQuery
  module HeightQuery: HeightQuery
}
