type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  blocks: array<HyperSyncClient.EventItems.blockHeader>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  transactionStore: TransactionStore.t,
  blockStore: BlockStore.t,
}

let reraiseIfRateLimited: exn => unit
let mapRateLimitedExn: exn => exn

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let extractMissingParams: exn => option<array<string>>

  let query: (
    ~client: HyperSyncClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~logSelections: array<LogSelection.t>,
    ~fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
    ~maxNumLogs: int,
  ) => promise<logsQueryPage>
}
