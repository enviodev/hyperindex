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
    ~context={
      chainId: ChainId.fromInt(0),
      ecosystem,
      onEventRegistrations,
      onBlockRegistrations,
      onTransactionRegistrations: [],
    },
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
  ~registrations: array<ChainRegistrations.Evm.input>,
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
      registrations: Evm({registrations: registrations}),
      shouldChecksum: false,
      contractRegisterIndexes: [],
      blockHandlers: [],
      transactionMasks: [],
      eventBlockMasks: [],
      transactionRegistrations: [],
    },
    addressStore,
  )

  (
    await page->buildAll(
      ~buffer,
      ~context={
        chainId: ChainId.fromInt(0),
        ecosystem: Evm,
        onEventRegistrations,
        onBlockRegistrations: [],
        onTransactionRegistrations: [],
      },
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
      registrations: ChainBuffer.emptyRegistrations(ecosystem),
      shouldChecksum: false,
      contractRegisterIndexes: [],
      blockHandlers: [],
      transactionMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.transactionMask
      ),
      eventBlockMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.blockMask
      ),
      transactionRegistrations: [],
    },
    TestAddresses.storeOf(~contracts=[], ~addresses=[]),
  )

// A chain's buffer over these registrations and addresses, built the way
// `ChainState` builds it: what a source reads its registrations from.
let forChain = (
  ~ecosystem=Ecosystem.Evm,
  ~onEventRegistrations: array<'registration>,
  ~onBlockRegistrations=[],
  ~addressStore,
  ~shouldChecksum=false,
) =>
  ChainBuffer.makeForChain(
    ~ecosystem,
    ~onEventRegistrations=onEventRegistrations->(
      Utils.magic: array<'registration> => array<Internal.onEventRegistration>
    ),
    ~onBlockRegistrations,
    ~shouldChecksum,
    ~addressStore,
  )

// A buffer over registrations already in the client's input shape.
let forInputs = (~evmRegistrations, ~addressStore) =>
  Core.getAddon().chainBuffer->ChainBuffer.make(
    {
      registrations: Evm({registrations: evmRegistrations}),
      shouldChecksum: false,
      contractRegisterIndexes: [],
      blockHandlers: [],
      transactionMasks: [],
      eventBlockMasks: [],
      transactionRegistrations: [],
    },
    addressStore,
  )

// The stored hash of one block.
let blockHashAt = (buffer, blockNumber) =>
  switch buffer->ChainBuffer.getBlockHashes(~fromBlock=blockNumber, ~belowBlock=blockNumber + 1) {
  | {hashes: [hash]} => Null.Value(hash)
  | _ => Null.Null
  }

// The rows a page carries, counted the way a merge keeps them.
let pageRowCount = (page, ~ecosystem=Ecosystem.Evm) =>
  (
    decodedBuffer(~onEventRegistrations=[], ~ecosystem)->ChainBuffer.mergePage(
      page,
      ~reorgThreshold=0,
      ~reportOnly=true,
    )
  ).rowsKept
