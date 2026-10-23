type itemsPage = {
  eventItems: array<FuelHyperSyncClient.Items.item>,
  blockItems: array<BlockItem.t>,
  rejectedLogData: array<FuelHyperSyncClient.Items.rejectedLogData>,
  nextBlock: int,
  archiveHeight: int,
  // Page store owning this page's raw blocks (built on the Rust side); its ids
  // drive reorg detection when merged into the chain store.
  blockStore: BlockStore.t,
}

module GetItems: {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query: (
    ~client: FuelHyperSyncClient.t,
    ~query: FuelHyperSyncClient.Items.query,
    ~addressSet: AddressSet.t,
  ) => promise<itemsPage>
}
