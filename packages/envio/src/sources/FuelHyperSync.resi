type logsQueryPage = {
  items: array<FuelHyperSyncClient.EventItems.item>,
  blocks: array<FuelHyperSyncClient.EventItems.block>,
  nextBlock: int,
  archiveHeight: int,
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
    ~addressesByContractName: dict<array<Address.t>>,
  ) => promise<logsQueryPage>
}
