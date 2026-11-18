let pageOf = (items: array<Internal.item>) => EventStore.fromJsItems(items)

// Takes every item out of the store the way a batch does. Transaction and
// block fields a registration selects are not read: a test that needs them
// awaits the read `StoredItems.takeWithFields` returns.
let takeAll = (store: EventStore.t, ~context: StoredItems.context): array<Internal.item> => {
  let (items, _) = store->StoredItems.takeWithFields(
    store->EventStore.length,
    ~context,
    ~fields={
      transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm),
      blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm),
      shouldChecksum: false,
    },
  )
  items
}

// The block number of every row the store holds, in order. The rows stay.
let blockNumbers = (store: EventStore.t) =>
  Array.fromInitializer(~length=store->EventStore.length, index =>
    store->EventStore.blockNumberAt(index)->Null.getUnsafe
  )

// A decoded EVM log as its item reports it.
type evmLog = {
  logIndex: int,
  srcAddress: Address.t,
  blockNumber: int,
  transactionIndex: int,
  onEventRegistrationIndex: int,
  params: Internal.eventParams,
}

// The EVM logs a source page holds, as the source routed them to
// `registrationIndexes`. Stand-in registrations up to the highest index select
// no field, so a log is read back through the item a batch would build.
let evmLogsOf = (page: EventStore.t, ~registrationIndexes: array<int>): array<evmLog> => {
  let onEventRegistrations = Array.fromInitializer(
    ~length=registrationIndexes->Array.reduce(0, (length, index) =>
      Pervasives.max(length, index + 1)
    ),
    index =>
      {
        "index": index,
        "eventConfig": {"contractName": "", "name": ""},
        "fieldSelection": {"transactionMask": 0., "blockMask": 0.},
      }->(Utils.magic: {..} => Internal.onEventRegistration),
  )
  page
  ->takeAll(~context={chainId: ChainId.fromInt(0), onEventRegistrations, onBlockRegistrations: []})
  ->Array.map(item => {
    let event = item->Internal.castUnsafeEventItem
    let payload = event.payload->(Utils.magic: Internal.eventPayload => {..})
    {
      logIndex: event.logIndex,
      srcAddress: payload["srcAddress"],
      blockNumber: event.blockNumber,
      transactionIndex: event.transactionIndex,
      onEventRegistrationIndex: event.onEventRegistration.index,
      params: payload["params"],
    }
  })
}
