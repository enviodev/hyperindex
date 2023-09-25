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

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams) | QueryError(QueryHelpers.queryError)

let queryErrorToMsq = (e: queryError): string => {
  let getMsgFromExn = (exn: exn) =>
    exn
    ->Js.Exn.asJsExn
    ->Belt.Option.flatMap(exn => exn->Js.Exn.message)
    ->Belt.Option.getWithDefault("No message on exception")
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  | QueryError(e) =>
    switch e {
    | Deserialize(e) =>
      `Failed to deserialize response: ${e.message}
        JSON data:
          ${e.value->Js.Json.stringify}`
    | FailedToFetch(e) =>
      let msg = e->getMsgFromExn

      `Failed during fetch query: ${msg}`
    | FailedToParseJson(e) =>
      let msg = e->getMsgFromExn
      `Failed during parse of json: ${msg}`
    | Other(e) =>
      let msg = e->getMsgFromExn
      `Failed for unknown reason during query: ${msg}`
    }
  }
}

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
