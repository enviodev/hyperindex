type logsQueryPage = {
  page: BufferPage.t,
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
    ~addressSet: AddressSet.t,
    ~clientFilteredContracts: option<array<string>>,
  ) => promise<logsQueryPage>
}
