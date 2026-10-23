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

module GetItems = {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let query = async (
    ~client: FuelHyperSyncClient.t,
    ~query: FuelHyperSyncClient.Items.query,
    ~addressSet,
  ): itemsPage => {
    let (res, blockStore) = switch await client->FuelHyperSyncClient.getItems(query, addressSet) {
    | res => res
    | exception exn =>
      switch exn->HyperSync.GetItems.extractMissingParams {
      | Some(missingParams) => throw(Error(UnexpectedMissingParams({missingParams: missingParams})))
      | None => throw(exn)
      }
    }
    if res.nextBlock <= query.fromBlock {
      // Might happen when /height response was from another instance of HyperFuel
      throw(Error(WrongInstance))
    }
    {
      eventItems: res.eventItems,
      blockItems: res.blockItems,
      rejectedLogData: res.rejectedLogData,
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), // TODO: FIXME: Shouldn't have a default here
      blockStore,
    }
  }
}
