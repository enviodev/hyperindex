type logsQueryPage = {
  items: array<FuelHyperSyncClient.EventItems.item>,
  nextBlock: int,
  archiveHeight: int,
  // Page store owning this page's raw blocks (built on the Rust side); its ids
  // drive reorg detection when merged into the chain store.
  blockStore: BlockStore.t,
}

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~client: FuelHyperSyncClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~registrationIndexes: array<int>,
    ~addressSet: AddressSet.t,
    ~clientFilteredContracts: option<array<string>>,
  ) => promise<logsQueryPage>
}
