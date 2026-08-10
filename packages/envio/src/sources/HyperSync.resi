type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  blocks: array<HyperSyncClient.EventItems.blockHeader>,
  nextBlock: int,
  archiveHeight: int,
  transactionStore: TransactionStore.t,
  blockStore: BlockStore.t,
}

// Map a native client's `PREFIX:<int>` failure marker onto the exception
// SourceManager retries on (`RateLimited` / `SourceBehindHead`), falling back to
// the original cause.
let mapNativeFailure: Source.nativeRequestFailure => exn
let mapNativeFailureExn: exn => exn
let reraiseIfRecoverable: exn => unit

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
    ~maxNumLogs: option<int>,
    ~registrationIndexes: array<int>,
    ~addressSet: AddressSet.t,
    ~clientFilteredContracts: option<array<string>>,
  ) => promise<logsQueryPage>
}
