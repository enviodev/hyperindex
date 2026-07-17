type logsQueryPage = {
  items: array<HyperFuelClient.EventItems.item>,
  blocks: array<HyperFuelClient.EventItems.block>,
  nextBlock: int,
  archiveHeight: int,
}

module GetLogs: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~client: HyperFuelClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~registrationIndexes: array<int>,
    ~addressesByContractName: dict<array<Address.t>>,
  ) => promise<logsQueryPage>
}
