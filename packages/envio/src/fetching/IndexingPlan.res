// Binding to the Rust `IndexingPlan` (`cli/src/indexing_plan/`): per chain,
// what is needed, what is covered, and the work out. The loop takes work from
// it and hands back what came of it; it does no IO itself.
type t

// A request handed out to run against a source, as it was when taken.
type fetchRequest

type eventRegistration = {
  index: int,
  contractName: string,
  dependsOnAddresses: bool,
  startBlock?: int,
}

type blockRegistration = {index: int, startBlock?: int}

type chainConfig = {
  chainId: ChainId.t,
  startBlock: int,
  endBlock?: int,
  blockLag: int,
  blockThrottle: int,
  knownHeight: int,
  progressBlockNumber: int,
  maxReorgDepth: int,
  shouldRollbackOnReorg: bool,
  maxAddressesPerGroup: int,
  addressFreeThreshold?: int,
  hasGeneratedBlockHandlers: bool,
  ecosystem: string,
  onEventRegistrations: array<eventRegistration>,
  fetchedBlockRegistrations: array<blockRegistration>,
  onTransactionRegistrations: array<blockRegistration>,
  isResumed: bool,
}

// What the plan has to tell an operator.
@tag("kind")
type notice =
  | SwitchedToAddressFree({contractName: string, addressCount: int, threshold: int})
  | WentAddressFreeNearHead({contractNames: array<string>})
  | SkippedInvalidAddress({contractName: string, contractAddress: Address.t})

type chainTick = {
  chainId: ChainId.t,
  processingBlockNumber: int,
  processedDensity?: float,
}

type chainFetchWork = {
  chainId: ChainId.t,
  waitForNewBlock: bool,
  requests: array<fetchRequest>,
}

type completion = {
  mismatch?: BufferPage.hashMismatch,
  rowsKept: int,
  registeringBlockCount: int,
  notices: array<notice>,
}

@send external make: Core.indexingPlanCtor => t = "make"

@send
external addChain: (t, chainConfig, AddressStore.t, ChainBuffer.t) => array<notice> = "addChain"

@send
external setKnownHeight: (t, ~chainId: ChainId.t, ~knownHeight: int) => array<notice> =
  "setKnownHeight"

@send external setBlockLag: (t, ~chainId: ChainId.t, ~blockLag: int) => unit = "setBlockLag"

@send
external setEndBlock: (t, ~chainId: ChainId.t, ~endBlock: Null.t<int>) => unit = "setEndBlock"

@send
external takeFetchRequestsToStart: (
  t,
  array<chainTick>,
  ~isRealtime: bool,
  ~targetBufferSize: int,
) => array<chainFetchWork> = "takeFetchRequestsToStart"

// Merges the page and moves coverage to the block the source reached. Null
// for a request a rollback has dropped.
@send
external completeFetchRequest: (
  t,
  fetchRequest,
  BufferPage.t,
  ~latestFetchedBlockNumber: int,
  ~sourceIndex: int,
  ~knownHeight: int,
) => Null.t<completion> = "completeFetchRequest"

@send external abandonFetchRequest: (t, fetchRequest) => unit = "abandonFetchRequest"

@send
external abandonFetchRequestsInFlight: (t, ~chainId: ChainId.t) => unit =
  "abandonFetchRequestsInFlight"

@send
external rollbackToBlock: (
  t,
  ~chainId: ChainId.t,
  ~blockNumber: int,
) => array<AddressStore.rolledBackAddress> = "rollbackToBlock"

@send external getReadyThroughBlock: (t, ~chainId: ChainId.t) => int = "getReadyThroughBlock"

@send
external getRequestStreamCount: (t, ~chainId: ChainId.t) => int = "getRequestStreamCount"

@send
external hasContractRegisterBacklog: (t, ~chainId: ChainId.t) => bool = "hasContractRegisterBacklog"

@send external isFetchingAtHead: (t, ~chainId: ChainId.t) => bool = "isFetchingAtHead"

@send
external takeContractRegisterBlocksToRun: (t, ~chainId: ChainId.t) => array<int> =
  "takeContractRegisterBlocksToRun"

@send
external completeContractRegisterRun: (
  t,
  ~chainId: ChainId.t,
  ~blockNumbers: array<int>,
  ~registrations: array<AddressStore.registration>,
) => array<notice> = "completeContractRegisterRun"

module Request = {
  type t = fetchRequest

  // What a request selects at one attempt's end block.
  type selection = {
    onEventRegistrationIndexes: array<int>,
    onBlockRegistrationIndexes: array<int>,
    onTransactionRegistrationIndexes: array<int>,
    // Contracts whose address-dependent events it fetches without an
    // address filter, gated against the chain's store instead.
    addressFreeContracts: array<string>,
  }

  @get external fromBlock: t => int = "fromBlock"
  @get external toBlockRaw: t => Null.t<int> = "toBlock"
  let toBlock = (request: t) => request->toBlockRaw->Null.toOption
  @get external itemsEstimate: t => int = "itemsEstimate"
  @get external addresses: t => array<Address.t> = "addresses"
  @get external addressCount: t => int = "addressCount"
  @send external selectionRaw: (t, Null.t<int>) => selection = "selection"
  let selection = (request: t, ~toBlock) => request->selectionRaw(toBlock->Null.fromOption)
  @send
  external containsAddressAt: (t, Address.t, ~contractName: string, ~blockNumber: int) => bool =
    "containsAddressAt"

  type standalone = {
    fromBlock: int,
    toBlock?: int,
    onEventRegistrationIndexes: array<int>,
    onBlockRegistrationIndexes: array<int>,
    onTransactionRegistrationIndexes: array<int>,
    addressFreeContracts: array<string>,
    // Only these of the contracts' addresses.
    addresses?: array<Address.t>,
  }
  @send
  external standaloneRaw: (Core.fetchRequestCtor, standalone, AddressStore.t, array<string>) => t =
    "standalone"

  // A request built outside a plan, for a source driven on its own: the
  // addresses the store holds for `contractNames`. No plan completes it.
  let standalone = (request: standalone, ~addressStore, ~contractNames) =>
    Core.getAddon().fetchRequest->standaloneRaw(request, addressStore, contractNames)
}
