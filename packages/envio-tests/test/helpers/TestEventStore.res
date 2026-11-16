// Every item a store holds, which it keeps. A row built in JS gets back a
// registration carrying only its index, which is all the fetch state tests'
// mock items have; any other row is rebuilt with `context`'s registrations.
let itemsOf = (store: EventStore.t, ~context: StoredItems.context): array<Internal.item> =>
  store
  ->EventStore.allItemsRaw
  ->StoredItems.build(~context, ~jsItemRegistration=(~kind as _, ~index) =>
    {"index": index}->(Utils.magic: {"index": int} => unknown)
  )

let pageOf = (items: array<Internal.item>) => EventStore.fromJsItems(items)

// The EVM logs a source page holds, as the source routed them. The routing
// test registrations stand in for real ones: a log is read back through the
// item it builds.
let evmLogsOf = (page: EventStore.t): array<EvmEventItem.t> => {
  let rows = page->EventStore.allItemsRaw
  let registrations = Array.fromInitializer(
    ~length=rows.params->Array.reduce(0, (max, {registrationIndex}) =>
      Pervasives.max(max, registrationIndex + 1)
    ),
    index =>
      {
        "index": index,
        "eventConfig": {"contractName": "", "name": ""},
      }->(Utils.magic: {..} => Internal.onEventRegistration),
  )
  rows
  ->StoredItems.build(
    ~context={
      chainId: ChainId.fromInt(0),
      onEventRegistrations: registrations,
      onBlockRegistrations: [],
    },
    ~jsItemRegistration=(~kind as _, ~index as _) => JsError.throwWithMessage("not an EVM log"),
  )
  ->Array.map(item => {
    let event = item->Internal.castUnsafeEventItem
    let payload = event.payload->(Utils.magic: Internal.eventPayload => {..})

    (
      {
        logIndex: event.logIndex,
        srcAddress: payload["srcAddress"],
        blockNumber: event.blockNumber,
        transactionIndex: event.transactionIndex,
        onEventRegistrationIndex: event.onEventRegistration.index,
        params: payload["params"],
      }: EvmEventItem.t
    )
  })
}

// For a chain built by hand, whose rows are all built in JS.
let noRegistrations = (~chainId): StoredItems.context => {
  chainId,
  onEventRegistrations: [],
  onBlockRegistrations: [],
}
