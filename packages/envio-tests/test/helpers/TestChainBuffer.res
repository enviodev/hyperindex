let pageOf = (items: array<Internal.item>, ~ecosystem=Ecosystem.Evm) =>
  BufferPage.fromItems(items, ~blocks=[], ~ecosystem)

// Merges the page into `buffer` and builds every item of blocks `[fromBlock,
// maxBlock]` the way a batch does: matched, decoded and joined.
let buildAll = async (
  page,
  ~buffer,
  ~context: StoredItems.context,
  ~fromBlock=0,
  ~maxBlock=1_000_000_000,
) => {
  let _ = buffer->ChainBuffer.mergePage(page, ~reorgThreshold=0, ~reportOnly=true)
  let built = await buffer->ChainBuffer.buildHandlerItems(
    ~fromBlock,
    ~maxBlock,
    ~targetItems=1_000_000_000,
  )
  built->StoredItems.read(~context)
}

// The items a page holds for a chain with these registrations.
let itemsOf = async (
  page,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~onBlockRegistrations=[],
  ~addressStore,
  ~ecosystem=Ecosystem.Evm,
  ~shouldChecksum=false,
  ~maxBlock=?,
) => {
  let buffer = ChainBuffer.makeForChain(
    ~ecosystem,
    ~onEventRegistrations,
    ~onBlockRegistrations,
    ~shouldChecksum,
    ~addressStore,
  )
  await page->buildAll(
    ~buffer,
    ~context={chainId: ChainId.fromInt(0), onEventRegistrations, onBlockRegistrations},
    ~maxBlock?,
  )
}

// A decoded EVM log as its item reports it.
type evmLog = {
  logIndex: int,
  srcAddress: Address.t,
  blockNumber: int,
  transactionIndex: int,
  onEventRegistrationIndex: int,
  params: Internal.eventParams,
}

// The EVM logs a source page holds, matched and decoded against
// `registrations` as a batch would. Stand-in registrations select no field, so
// a log is read back through the item a batch would build.
let evmLogsOf = async (
  page,
  ~registrations: array<HyperSyncClient.Registration.input>,
  ~addressStore,
): array<evmLog> => {
  let onEventRegistrations = Array.fromInitializer(
    ~length=registrations->Array.reduce(0, (length, registration) =>
      Pervasives.max(length, registration.index + 1)
    ),
    index =>
      {
        "index": index,
        "eventConfig": {"contractName": "", "name": ""},
        "fieldSelection": {"transactionMask": 0., "blockMask": 0.},
      }->(Utils.magic: {..} => Internal.onEventRegistration),
  )
  let buffer = Core.getAddon().chainBuffer->ChainBuffer.make(
    {
      ecosystem: "evm",
      shouldChecksum: false,
      evmRegistrations: registrations,
      contractRegisterIndexes: [],
      blockHandlers: [],
      transactionMasks: [],
      eventBlockMasks: [],
    },
    addressStore,
  )

  (
    await page->buildAll(
      ~buffer,
      ~context={chainId: ChainId.fromInt(0), onEventRegistrations, onBlockRegistrations: []},
    )
  )->Array.map(item => {
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

// A buffer for items built in JS, whose registrations select the fields
// their masks say.
let decodedBuffer = (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~ecosystem=Ecosystem.Evm,
) =>
  Core.getAddon().chainBuffer->ChainBuffer.make(
    {
      ecosystem: (ecosystem :> string),
      shouldChecksum: false,
      contractRegisterIndexes: [],
      blockHandlers: [],
      transactionMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.transactionMask
      ),
      eventBlockMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.blockMask
      ),
    },
    TestAddresses.storeOf(~contracts=[], ~addresses=[]),
  )
