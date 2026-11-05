type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  apiToken: option<string>,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.onEventRegistration>,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
  logger: Logger.t,
}

let make = (
  {chainId, endpointUrl, apiToken, onEventRegistrations, addressStore, logger}: options,
): Source.t => {
  // Registration indexes already warned about undecodable LogData — a stale
  // ABI rejects every receipt, so one line per event is enough.
  let rejectedLogDataWarned = Utils.Set.make()

  let apiToken = apiToken->HyperSync.requireApiToken

  let client = switch FuelHyperSyncClient.make(
    {url: endpointUrl, apiToken},
    ~eventRegistrations=FuelHyperSyncClient.Registration.fromOnEventRegistrations(
      onEventRegistrations,
    ),
    ~addressStore,
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to instantiate the HyperFuel client")
  }

  let decodeItemsPage = (
    page: NativeSource.page,
    ~knownHeight as _,
  ): Source.blockRangeFetchResponse => {
    let page = page->(Utils.magic: NativeSource.page => FuelHyperSyncClient.EventItems.page)
    let parsingTimeRef = Performance.now()

    page.rejectedLogData->Array.forEach(rejected => {
      if !(rejectedLogDataWarned->Utils.Set.has(rejected.onEventRegistrationIndex)) {
        rejectedLogDataWarned->Utils.Set.add(rejected.onEventRegistrationIndex)->ignore
        let eventConfig = (
          onEventRegistrations->Array.getUnsafe(rejected.onEventRegistrationIndex)
        ).eventConfig
        logger->Logger.warn(
          `Skipped ${eventConfig.contractName}.${eventConfig.name} LogData receipts whose data doesn't decode against the contract ABI. Check that the ABI matches the deployed contract.`,
          ~params={
            "blockNumber": rejected.blockHeight,
            "logIndex": rejected.receiptIndex,
            "txId": rejected.txId,
            "dataLength": rejected.dataLength,
            "skippedInPage": rejected.count,
          },
        )
      }
    })

    let parsedQueueItems = page.items->Array.map(item => {
      // Routing happened in Rust; the item references its registration by
      // chain-scoped index.
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex)
      let eventConfig =
        onEventRegistration.eventConfig->(
          Utils.magic: Internal.eventConfig => Internal.fuelEventConfig
        )

      let params = switch eventConfig.kind {
      // Rust only routes a LogData receipt once its data decoded.
      | LogData(_) => item.params->Option.getUnsafe
      | Mint | Burn =>
        (
          {
            subId: item.subId->Option.getOr(""),
            amount: item.val->Option.getOr(0n),
          }: Internal.fuelSupplyParams
        )->Obj.magic
      | Transfer | Call =>
        (
          {
            to: item.to->Option.getOr("")->Address.unsafeFromString,
            assetId: item.assetId->Option.getOr(""),
            amount: item.amount->Option.getOr(0n),
          }: Internal.fuelTransferParams
        )->Obj.magic
      }

      Internal.Event({
        onEventRegistration,
        chainId,
        blockNumber: item.blockHeight,
        logIndex: item.receiptIndex,
        // Fuel carries the transaction inline on the payload; the store key is
        // unused (Fuel identifies transactions by hash, kept on the payload).
        transactionIndex: 0,
        payload: {
          contractName: eventConfig.contractName,
          eventName: eventConfig.name,
          chainId,
          params,
          transaction: {
            "id": item.txId,
          }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
          // `block` is omitted; it's materialised from the block store onto the
          // payload at batch prep (like EVM/SVM).
          srcAddress: item.srcAddress,
          logIndex: item.receiptIndex,
        }->Fuel.fromPayload,
      })
    })

    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    {
      parsedQueueItems,
      // Fuel keeps transaction and block inline on the payload; the block store
      // carries only the (height, id) rows that drive reorg detection (Fuel
      // never rolls back, so it's detect-only logging).
      transactionStore: None,
      blockStore: page.blocks,
      latestFetchedBlockNumber: page.toBlock,
      stats: {
        totalTimeElapsed: page.fetchSeconds +. parsingTimeElapsed,
        parsingTimeElapsed,
        pageFetchTime: page.fetchSeconds,
      },
      knownHeight: page.knownHeight,
      // Already reported by the source manager.
      requestStats: [],
    }
  }

  {
    name: "HyperFuel",
    sourceFor: Sync,
    chainId,
    pollingInterval: HyperSync.pollingInterval,
    poweredByHyperSync: true,
    implementation: Rust({source: client->FuelHyperSyncClient.source, decodeItemsPage}),
  }
}
