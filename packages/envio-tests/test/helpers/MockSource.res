// A promise the code under test awaits, held closed until the test opens it.
// Wrap a storage method in `gate.wait()` to stall it and observe the indexer
// while it is blocked, instead of guessing with `Utils.delay`.
module Gate = {
  type t = {
    // How many times the gate was entered, whether or not it was open.
    entered: ref<int>,
    wait: unit => promise<unit>,
    release: unit => unit,
  }

  let make = () => {
    let waiting = []
    let isOpen = ref(false)
    let entered = ref(0)
    {
      entered,
      wait: () => {
        entered := entered.contents + 1
        if isOpen.contents {
          Promise.resolve()
        } else {
          Promise.make((resolve, _reject) => waiting->Array.push(() => resolve())->ignore)
        }
      },
      release: () => {
        isOpen := true
        waiting->Array.forEach(resolve => resolve())
        waiting->Utils.Array.clearInPlace
      },
    }
  }
}

// EVM block hashes are the fixed 32-byte reorg comparison key, and the store
// rejects anything narrower. Widen the short markers fixtures use, both on the
// way into a mocked response and in assertions that compare against
// `BlockStore.getHash` output (e.g. persisted reorg checkpoints).
let evmBlockHash = hex =>
  "0x" ++ hex->String.slice(~start=2, ~end=hex->String.length)->String.padStart(64, "0")

type mockSourceHandler = Internal.handlerArgs => promise<unit>
type mockSourceContractRegister = Internal.contractRegisterArgs => promise<unit>
type mockSourceEvent = {
  __mockHandler?: mockSourceHandler,
  __mockPreloadHandler?: mockSourceHandler,
  __mockContractRegister?: mockSourceContractRegister,
}

// MockSource items choose their callback at response time, after ChainState has
// already been created. Install one stable registration up front and dispatch
// through callback metadata carried only by the test payload.
let makeMockSourceRegistration = (
  ~index,
  ~contractName,
  ~isWildcard,
): Internal.onEventRegistration => {
  let handler: Internal.handler = args => {
    let event = args.event->(Utils.magic: Internal.event => mockSourceEvent)
    if args.context.isPreload {
      switch event.__mockPreloadHandler {
      | Some(handler) => handler(args)
      | None => Promise.resolve()
      }
    } else {
      switch event.__mockHandler {
      | Some(handler) => handler(args)
      | None => Promise.resolve()
      }
    }
  }
  let contractRegister: Internal.contractRegister = args => {
    let event = args.event->(Utils.magic: Internal.event => mockSourceEvent)
    switch event.__mockContractRegister {
    | Some(contractRegister) => contractRegister(args)
    | None => Promise.resolve()
    }
  }
  ({
    index,
    eventConfig: ({
      // Keep the synthetic registration in the same address-dependent fetch
      // partition as the config's registrations. MockSource ignores the
      // query selection, while ChainState still owns and resolves this slot.
      contractName,
      name: "MockEvent",
      paramsRawEventSchema: EventConfigBuilder.buildParamsSchema([]),
      simulateParamsSchema: EventConfigBuilder.buildSimulateParamsSchema([]),
      fieldSelection: Internal.makeFieldSelection(
        ~blockFields=Utils.Set.make(),
        ~transactionFields=Utils.Set.make(),
        ~blockMaskFn=Evm.eventBlockFieldMask,
        ~transactionMaskFn=Evm.eventTransactionFieldMask,
      ),
      sighash: Some(""),
      topicCount: 1,
      paramsMetadata: [],
    }: Internal.evmEventConfig :> Internal.eventConfig),
    isWildcard,
    filterByAddresses: false,
    dependsOnAddresses: !isWildcard,
    startBlock: None,
    handler,
    contractRegister: Some(contractRegister),
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.make(),
      ~transactionFields=Utils.Set.make(),
      ~blockMaskFn=Evm.eventBlockFieldMask,
      ~transactionMaskFn=Evm.eventTransactionFieldMask,
    ),
    resolvedWhere: {topicFilters: [], startBlock: None},
  }: Internal.evmOnEventRegistration :> Internal.onEventRegistration)
}

type mockSourceRegistrationRef = ref<option<Internal.onEventRegistration>>
// `isWildcard` decides whether the chain's mock registration depends on
// addresses, and so whether its partition is an address partition or a wildcard
// one — the two take different paths through a rollback.
type mockSourceState = {onEventRegistrationRef: mockSourceRegistrationRef, isWildcard: bool}
@get external getMockSourceState: Source.t => option<mockSourceState> = "__mockSourceState"

let setMockSourceState = (source: Source.t, state: mockSourceState) => {
  source
  ->Utils.Object.definePropertyWithValue("__mockSourceState", {enumerable: false, value: state})
  ->ignore
}

let installMockSourceRegistrations = (
  ~config: Config.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
) =>
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let sourceStates = switch chainConfig.sourceConfig {
    | Config.CustomSources(sources) =>
      sources->Array.filterMap(source => source->getMockSourceState)
    | _ => []
    }
    // A chain without contracts has no address index for the synthetic
    // registration to live in, and nothing for a mock item to be delivered to.
    switch chainConfig.contracts->Array.get(0) {
    | Some(contract) if !(sourceStates->Utils.Array.isEmpty) =>
      let key = chainConfig.id->ChainId.toString
      let registrations = switch registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(registrations) => registrations
      | None =>
        let registrations: HandlerRegister.chainRegistrations = {
          onEventRegistrations: [],
          onBlockRegistrations: [],
        }
        registrationsByChainId->Dict.set(key, registrations)
        registrations
      }
      let mockRegistration = makeMockSourceRegistration(
        ~isWildcard=sourceStates->Array.some(state => state.isWildcard),
        ~index=registrations.onEventRegistrations->Array.length,
        // Any contract from the chain keeps the synthetic registration in the
        // address-dependent partition of a real contract.
        ~contractName=contract.name,
      )
      registrations.onEventRegistrations->Array.push(mockRegistration)->ignore
      sourceStates->Array.forEach(state => state.onEventRegistrationRef := Some(mockRegistration))
    | _ => ()
    }
  })

type method = [
  | #getBlockHashes
  | #getHeightOrThrow
  | #getItemsOrThrow
  | #createHeightSubscription
]

type itemMock = {
  blockNumber: int,
  logIndex: int,
  handler?: mockSourceHandler,
  // Run in the handler's place while its batch preloads; the handler itself
  // only runs once preloading is done.
  preloadHandler?: mockSourceHandler,
  contractRegister?: mockSourceContractRegister,
  // Laid over the number, timestamp and hash every item's block carries.
  blockFields?: dict<unknown>,
  transactionFields?: dict<unknown>,
}

// Unboxed so a failed `toEqual` prints `100` or `"unbounded"`, not a tagged object.
@unboxed type toBlock = Bounded(int) | @as("unbounded") Unbounded

type startupHeight = Height(int) | HeightFailure(string)

// What a test can tell one pending item query from another by.
type pendingItemsQuery = {
  partitionId: string,
  fromBlock: int,
  toBlock: toBlock,
  retryCount: int,
}

// Non-enumerable on the query, so a whole-value `toEqual` snapshot of the
// pending queries doesn't have to spell them out.
@get external addresses: pendingItemsQuery => array<Address.t> = "addresses"
@get external includeAllBlocks: pendingItemsQuery => bool = "includeAllBlocks"

type itemsResponse = {
  items: array<itemMock>,
  // Defaults to the query's toBlock, or its fromBlock when unbounded.
  latestFetchedBlockNumber?: int,
  latestFetchedBlockHash?: string,
  knownHeight?: int,
  prevRangeLastBlock?: ReorgDetection.blockData,
  requestStats?: array<Source.requestStat>,
}

type reply =
  | Respond(itemsResponse)
  // For a response that depends on the query it matched, e.g. items at its fromBlock.
  | RespondWith(pendingItemsQuery => itemsResponse)
  // A reply no real source gives: past the query's toBlock, or with items
  // outside the range it reports. Only for testing the indexer's defence
  // against one; `Respond` refuses it.
  | RespondUnchecked(itemsResponse)
  | Fail(exn)
  | LeavePending

type expectedItemsQuery = {
  partitionId?: string,
  fromBlock?: int,
  toBlock?: toBlock,
  retryCount?: int,
  coversBlock?: int,
  where?: pendingItemsQuery => bool,
  reply: reply,
}

type expectedBlockHashLookup = {
  blockNumbers: array<int>,
  // Short hashes (`"0x200"`) are widened like a mocked items response's, so the
  // block's stored hash is `0x<blockNumber>` and anything else reads as re-orged.
  reply: array<BlockStore.inputBlock>,
}

type pendingItemsQueryControl = {
  respond: itemsResponse => unit,
  fail: exn => unit,
}
@get external control: pendingItemsQuery => pendingItemsQueryControl = "__control"

type t = {
  source: Source.t,
  // Use array of bool instead of array of unit,
  // for better logging during debugging
  getHeightOrThrowCalls: array<bool>,
  // Answers every height call in flight, or — with none in flight — the next one
  // to arrive. A chain has one head, so unlike an item query there is nothing to
  // choose between here.
  resolveGetHeightOrThrow: int => unit,
  // Answers a single height request instead of every one at once, for tests
  // where which of two in-flight calls answers is the point. The index counts
  // every call the source has taken, in the order it took them — including calls
  // a standing height answered on the spot — and answering one that has already
  // settled does nothing. An index for a call the source never took throws.
  resolveGetHeightOrThrowAt: (~index: int, int) => unit,
  rejectGetHeightOrThrow: 'exn. 'exn => unit,
  // Waits until the source has taken `count` height calls in all, then fails
  // if it has taken more. Answering them is still up to the resolvers above.
  expectHeightCalls: int => promise<unit>,
  // Answer every height call with `height` from now on, one answer covering any
  // number of polls. A restarted indexer learns the head on its own this way,
  // before the test body gets a chance to resolve anything.
  setAutoHeight: int => unit,
  // How many times the source was told to drop orphaned-chain state.
  reorgCallCount: unit => int,
  // The item queries the source has taken and not yet replied to, in arrival
  // order. A query leaves as soon as it is replied to. A rollback doesn't cancel
  // the ones already in flight: they stay next to the re-queries it issues, so
  // pin `fromBlock` to tell a re-query from the query it superseded.
  pendingItemsQueries: array<pendingItemsQuery>,
  // Waits until every entry matches a pending query, then replies to all of
  // them in list order. An entry that replies needs exactly one matching query;
  // `LeavePending` accounts for every remaining query it matches. A pending
  // query no entry accounts for, and no earlier list left pending, fails it.
  expectItemsQueries: array<expectedItemsQuery> => promise<unit>,
  // Lets the chain fetch empty ranges up to `blockNumber`: waits for each wave of
  // queries and answers every one up to its own toBlock, never past
  // `blockNumber`, until every partition it answers gets there. A query starting
  // past `blockNumber` fails it as unlisted, like any query no entry names. For
  // a test that just needs the chain somewhere.
  respondEmptyUpTo: int => promise<unit>,
  // Empty-responds every pending query, up to its own toBlock unless
  // `~latestFetchedBlockNumber` says otherwise. Never waits, and throws with none.
  drainPendingItemsQueries: (~latestFetchedBlockNumber: int=?) => unit,
  getBlockHashesCalls: array<array<int>>,
  // Answers every block-hash lookup in flight, and throws when there is none.
  resolveGetBlockHashes: array<BlockStore.inputBlock> => unit,
  // Answers every block-hash lookup in flight with a failure the source
  // reported, and throws when there is none. `requestStats` are the requests
  // the failed lookup made, reported on the response as a native source does.
  failGetBlockHashes: (exn, ~requestStats: array<Source.requestStat>=?) => unit,
  // Waits for the rollback's block-hash lookup of exactly `blockNumbers`, then
  // replies with `reply`. A lookup of other blocks, or more than one pending,
  // fails at once naming what was asked. A rollback only looks up hashes when
  // the chain has a stored block between its threshold and the reorged block.
  expectBlockHashLookup: expectedBlockHashLookup => promise<unit>,
  // What the source has been asked and not answered, for a failure report.
  describeState: unit => string,
  // Throws if a height answer given before its call arrived is still waiting
  // for one, naming the call sites. Run at the end of a passing scenario.
  validateAnswersClaimed: unit => unit,
  // Voids the queries the indexer has in flight. A restarted indexer re-issues
  // its own, and answering a stopped indexer's leftovers instead is a bug the
  // test can neither see nor mean.
  dropPendingCalls: unit => unit,
  // Height subscription mocking
  heightSubscriptionCalls: array<bool>,
  // Closes performed by the consumer, as opposed to the ones this mock's own
  // `unsubscribeHeightSubscription` simulates.
  heightSubscriptionCloseCalls: array<bool>,
  triggerHeightSubscription: int => unit,
  setHeightSubscriptionStatus: Source.heightSubscriptionStatus => unit,
  unsubscribeHeightSubscription: unit => unit,
}

// The Rust ledger (`mock_source.rs`) that records every call the source takes
// and decides what a test's expectations match. It answers nothing: each call
// comes back with an id, each answer with the ids to settle, and the promises
// they settle stay here.
module Ledger = {
  type t

  type startupHeight = {height?: int, failure?: string}
  type heightCall = {index: int, height: Nullable.t<int>, failure: Nullable.t<string>}
  type query = {
    id: int,
    partitionId: string,
    fromBlock: int,
    toBlock: Nullable.t<int>,
    retryCount: int,
  }
  type expected = {
    partitionId?: string,
    fromBlock?: int,
    toBlock?: int,
    toBlockUnbounded?: bool,
    retryCount?: int,
    coversBlock?: int,
    whereIds?: array<int>,
    reply: string,
  }
  type itemsMatch = {
    status: string,
    assignment: array<int>,
    leftPending: array<int>,
    message: Nullable.t<string>,
  }
  type reply = {
    id: int,
    checked: bool,
    isFailure: bool,
    latestFetchedBlockNumber?: int,
    itemBlockNumbers: array<int>,
  }
  type drainReply = {id: int, latestFetchedBlockNumber: Nullable.t<int>}
  type heightCallsCheck = {done: bool, error: Nullable.t<string>}
  type lookupMatch = {status: string, id: Nullable.t<int>, message: Nullable.t<string>}

  @send
  external make: (Core.mockSourceCtor, int, Null.t<int>, array<startupHeight>) => t = "new"
  @send external takeHeightCall: t => heightCall = "takeHeightCall"
  @send external resolveHeight: (t, int, string) => array<int> = "resolveHeight"
  @send external resolveHeightAt: (t, int) => bool = "resolveHeightAt"
  @send external setAutoHeight: (t, int) => array<int> = "setAutoHeight"
  @send external rejectHeights: t => array<int> = "rejectHeights"
  @send external checkHeightCalls: (t, int) => heightCallsCheck = "checkHeightCalls"
  @send external heightCallsTimeoutMessage: (t, int) => string = "heightCallsTimeoutMessage"
  @send external unclaimedAnswersMessage: t => Nullable.t<string> = "unclaimedAnswersMessage"
  @send
  external takeItemsQuery: (t, string, int, Null.t<int>, int) => int = "takeItemsQuery"
  @send external pendingItemsQueries: t => array<query> = "pendingItemsQueries"
  @send external settleItemsQuery: (t, int) => unit = "settleItemsQuery"
  @send external matchItemsQueries: (t, array<expected>) => itemsMatch = "matchItemsQueries"
  @send external keepPending: (t, array<int>) => unit = "keepPending"
  @send external checkReplies: (t, array<reply>) => Nullable.t<string> = "checkReplies"
  @send
  external drainItemsQueries: (t, Null.t<int>) => array<drainReply> = "drainItemsQueries"
  @send external takeBlockHashLookup: (t, array<int>) => int = "takeBlockHashLookup"
  @send
  external settleAllBlockHashLookups: (t, string) => array<int> = "settleAllBlockHashLookups"
  @send external matchBlockHashLookup: (t, array<int>) => lookupMatch = "matchBlockHashLookup"
  @send external recordReorg: t => unit = "recordReorg"
  @send external reorgCallCount: t => int = "reorgCallCount"
  @send external describeState: t => string = "describeState"
  @send external dropPendingCalls: t => array<int> = "dropPendingCalls"
}

let blockHashesResponse = (blocks: array<BlockStore.inputBlock>) => {
  Source.result: Ok(
    BlockStore.fromJs(
      blocks->Array.map((block): BlockStore.inputBlock => {
        ...block,
        blockHash: ?(block.blockHash->Option.map(evmBlockHash)),
      }),
      ~ecosystem=Evm,
    ),
  ),
  requestStats: [],
}

// Taken at module load, before a test can fake the clock: a deadline on faked
// timers never fires, and a mismatched expectation would hang the suite instead
// of failing with what it was waiting for.
let realSetTimeout: (
  unit => unit,
  int,
) => timeoutId = %raw(`globalThis.setTimeout.bind(globalThis)`)
let realClearTimeout: timeoutId => unit = %raw(`globalThis.clearTimeout.bind(globalThis)`)
@val external queueMicrotask: (unit => unit) => unit = "queueMicrotask"

let realNow: unit => float = %raw(`Date.now.bind(Date)`)

// The ledger's id for a query, kept off the enumerable fields a test compares.
@get external queryId: pendingItemsQuery => int = "__id"

let replyName = (reply: reply) =>
  switch reply {
  | Respond(_) => "Respond"
  | RespondWith(_) => "RespondWith"
  | RespondUnchecked(_) => "RespondUnchecked"
  | Fail(_) => "Fail"
  | LeavePending => "LeavePending"
  }

let make = (
  methods: array<method>,
  ~chainId=1,
  ~sourceFor=Source.Sync,
  ~pollingInterval=1000,
  ~isWildcard=false,
  // Pre-configures the standing height answer at construction time, before
  // the mock is handed to the indexer - needed for a call that happens during
  // startup itself (e.g. resolving a `latest` start block), which completes
  // before a test body would ever get a chance to call `setAutoHeight`.
  ~autoHeight=?,
  // Answers for the first height calls, one per call and in order, ahead of
  // `autoHeight`. For calls startup makes before a test body can answer them,
  // where a source has to fail first.
  ~startupHeights: array<startupHeight>=[],
) => {
  let implement = (method: method, fn) => {
    if methods->Array.includes(method) {
      fn
    } else {
      (() => JsError.throwWithMessage(`source.${(method :> string)} not implemented`))->Obj.magic
    }
  }

  let ledger = Core.getAddon().mockSource->Ledger.make(
    chainId,
    autoHeight->Null.fromOption,
    startupHeights->Array.map((answer): Ledger.startupHeight =>
      switch answer {
      | Height(height) => {height: height}
      | HeightFailure(failure) => {failure: failure}
      }
    ),
  )
  let chainId = chainId->ChainId.fromInt
  let getHeightOrThrowCalls = []
  let heightCallers: Map.t<
    int,
    {"resolve": Source.getHeightResponse => unit, "reject": exn => unit},
  > = Map.make()
  let settleHeightCalls = (indices, answer) =>
    indices->Array.forEach(index =>
      switch heightCallers->Map.get(index) {
      | Some(caller) =>
        heightCallers->Map.delete(index)->ignore
        answer(caller)
      | None => ()
      }
    )
  let answerHeight = height => caller => caller["resolve"]({Source.height, requestStats: []})
  let getBlockHashesCalls = []
  let blockHashCallers: Map.t<int, Source.getBlockHashesResponse => unit> = Map.make()
  let settleBlockHashLookups = (ids, response) =>
    ids->Array.forEach(id =>
      switch blockHashCallers->Map.get(id) {
      | Some(resolve) =>
        blockHashCallers->Map.delete(id)->ignore
        resolve(response)
      | None => ()
      }
    )
  // Height subscription state
  let heightSubscriptionCalls = []
  let heightSubscriptionCloseCalls = []
  let heightSubscriptionCallbacks: array<int => unit> = []
  let heightSubscriptionStatusCallbacks: array<Source.heightSubscriptionStatus => unit> = []
  let heightSubscriptionUnsubscribed = ref(false)
  // Shared by the close function the subscription hands back and the test-facing
  // unsubscribe, so a callback array added here cannot end up cleared by only
  // one of them.
  let teardownHeightSubscription = () => {
    heightSubscriptionUnsubscribed := true
    heightSubscriptionCallbacks->Utils.Array.clearInPlace
    heightSubscriptionStatusCallbacks->Utils.Array.clearInPlace
  }
  let state: mockSourceState = {onEventRegistrationRef: ref(None), isWildcard}

  // The ledger's pending queries as the objects a test holds, so the same query
  // stays the same object for as long as it is pending.
  let pendingItemsQueries: array<pendingItemsQuery> = []
  let queriesById: Map.t<int, pendingItemsQuery> = Map.make()
  let syncPendingQueries = () => {
    pendingItemsQueries->Utils.Array.clearInPlace
    ledger
    ->Ledger.pendingItemsQueries
    ->Array.forEach(({id}) =>
      queriesById->Map.get(id)->Option.forEach(query => pendingItemsQueries->Array.push(query))
    )
  }

  let arrivalListeners: array<unit => unit> = []
  // A chain fans out one query per partition, and each await on the way to the
  // source spreads the fan-out over one more microtask. Listeners are told once
  // `quietMicrotasks` turns pass with nothing new arriving, so they see the
  // fan-out as one wave. Waiting on microtasks rather than a timer keeps I/O
  // from completing in between, which would make what the indexer does next
  // depend on how fast the database answered.
  let quietMicrotasks = 20
  let arrivalGeneration = ref(0)
  let settling = ref(false)
  let notifyArrival = () => {
    arrivalGeneration := arrivalGeneration.contents + 1
    if !settling.contents {
      settling := true
      let rec settle = (~generation, ~quiet) =>
        queueMicrotask(() =>
          if arrivalGeneration.contents !== generation {
            settle(~generation=arrivalGeneration.contents, ~quiet=0)
          } else if quiet < quietMicrotasks {
            settle(~generation, ~quiet=quiet + 1)
          } else {
            settling := false
            let listeners = arrivalListeners->Array.copy
            arrivalListeners->Utils.Array.clearInPlace
            listeners->Array.forEach(listener => listener())
          }
        )
      settle(~generation=arrivalGeneration.contents, ~quiet=0)
    }
  }
  let nextArrival = (~deadline) =>
    Promise.make((resolve, _reject) => {
      let timer = realSetTimeout(
        () => resolve(false),
        Math.max(0., deadline -. realNow())->Float.toInt,
      )
      arrivalListeners
      ->Array.push(() => {
        realClearTimeout(timer)
        resolve(true)
      })
      ->ignore
    })
  // A burst still landing would have its first call taken for all of it.
  let awaitSettled = async (~deadline) =>
    if settling.contents {
      let _ = await nextArrival(~deadline)
    }

  let toLedgerExpected = (entry: expectedItemsQuery): Ledger.expected => {
    partitionId: ?entry.partitionId,
    fromBlock: ?entry.fromBlock,
    toBlock: ?switch entry.toBlock {
    | Some(Bounded(toBlock)) => Some(toBlock)
    | Some(Unbounded) | None => None
    },
    toBlockUnbounded: ?switch entry.toBlock {
    | Some(Unbounded) => Some(true)
    | Some(Bounded(_)) | None => None
    },
    retryCount: ?entry.retryCount,
    coversBlock: ?entry.coversBlock,
    // A predicate only JS can run, so the ledger is told what it accepted.
    whereIds: ?(
      entry.where->Option.map(where => pendingItemsQueries->Array.filter(where)->Array.map(queryId))
    ),
    reply: entry.reply->replyName,
  }

  let makeItemsResponse = (
    response: itemsResponse,
    ~fromBlock,
    ~toBlock,
    ~knownHeight,
  ): Source.blockRangeFetchResponse => {
    let items = response.items
    let latestFetchedBlockNumber =
      response.latestFetchedBlockNumber->Option.getOr(toBlock->Option.getOr(fromBlock))

    // The store takes 32-byte hashes, so widen the decimal marker.
    let mockBlockHash = blockNumber => evmBlockHash(`0x${blockNumber->Int.toString}`)
    let latestFetchedBlockHash = switch response.latestFetchedBlockHash {
    | Some(latestFetchedBlockHash) => latestFetchedBlockHash
    | None => mockBlockHash(latestFetchedBlockNumber)
    }
    let observedBlocks = [
      (
        {
          blockNumber: latestFetchedBlockNumber,
          blockHash: evmBlockHash(latestFetchedBlockHash),
          blockTimestamp: latestFetchedBlockNumber,
        }: BlockStore.inputBlock
      ),
    ]
    let prevEntry = switch response.prevRangeLastBlock {
    | Some(prevRangeLastBlock: ReorgDetection.blockData) =>
      Some(
        (
          {
            blockNumber: prevRangeLastBlock.blockNumber,
            blockHash: evmBlockHash(prevRangeLastBlock.blockHash),
          }: BlockStore.inputBlock
        ),
      )
    | None =>
      if fromBlock > 0 {
        Some(
          (
            {
              blockNumber: fromBlock - 1,
              blockHash: mockBlockHash(fromBlock - 1),
            }: BlockStore.inputBlock
          ),
        )
      } else {
        None
      }
    }
    switch prevEntry {
    | Some(prev) => observedBlocks->Array.unshift(prev)->ignore
    | None => ()
    }
    // A real source returns the header of every block a matched item came
    // from, so those blocks carry a hash and a timestamp too. Without them the
    // store only ever learns the range's seam and end, and reorg detection
    // never sees the blocks events landed on.
    items->Array.forEach(item => {
      if !(observedBlocks->Array.some(b => b.blockNumber === item.blockNumber)) {
        observedBlocks->Array.push({
          blockNumber: item.blockNumber,
          blockHash: mockBlockHash(item.blockNumber),
          blockTimestamp: item.blockNumber,
        })
      }
    })
    let responseBlockStore = BlockStore.make(~ecosystem=Evm)
    observedBlocks->Array.forEach(block => {
      let page = BlockStore.fromJs([block], ~ecosystem=Evm)
      responseBlockStore->BlockStore.appendPage(page)
    })
    {
      knownHeight: response.knownHeight->Option.getOr(knownHeight),
      parsedQueueItems: items->Array.map(item => {
        let onEventRegistration =
          state.onEventRegistrationRef.contents->Option.getOrThrow(
            ~message="MockSource on-event registration was not installed before resolving items",
          )
        let payload: Evm.payload = {
          contractName: onEventRegistration.eventConfig.contractName,
          eventName: onEventRegistration.eventConfig.name,
          params: %raw(`{}`),
          chainId,
          srcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          logIndex: item.logIndex,
          block: Dict.fromArray([
            ("number", item.blockNumber->(Utils.magic: int => unknown)),
            ("timestamp", item.blockNumber->(Utils.magic: int => unknown)),
            ("hash", `0x${item.blockNumber->Int.toString}`->(Utils.magic: string => unknown)),
          ])
          ->Dict.assign(item.blockFields->Option.getOr(Dict.make()))
          ->(Utils.magic: dict<unknown> => Internal.eventBlock),
          transaction: ?(
            item.transactionFields->Option.map(fields =>
              fields->(Utils.magic: dict<unknown> => Internal.eventTransaction)
            )
          ),
        }
        let _ = %raw(`Object.defineProperties(payload, {
          __mockHandler: {value: item.handler},
          __mockPreloadHandler: {value: item.preloadHandler},
          __mockContractRegister: {value: item.contractRegister},
        })`)
        Internal.Event({
          onEventRegistration,
          chainId,
          blockNumber: item.blockNumber,
          logIndex: item.logIndex,
          transactionIndex: 0,
          payload: payload->Evm.fromPayload,
        })
      }),
      transactionStore: None,
      blockStore: responseBlockStore,
      latestFetchedBlockNumber,
      stats: {
        totalTimeElapsed: 0.,
      },
      requestStats: response.requestStats->Option.getOr([]),
    }
  }

  let expectItemsQueries = async expected => {
    let deadline = realNow() +. 2000.
    let rec awaitMatch = async () => {
      await awaitSettled(~deadline)
      let outcome = ledger->Ledger.matchItemsQueries(expected->Array.map(toLedgerExpected))
      let message = () => outcome.message->Nullable.toOption->Option.getOr("")
      switch outcome.status {
      | "matched" => outcome
      | "wait" =>
        if await nextArrival(~deadline) {
          await awaitMatch()
        } else {
          JsError.throwWithMessage(message())
        }
      | _ => JsError.throwWithMessage(message())
      }
    }
    let {assignment, leftPending} = await awaitMatch()
    ledger->Ledger.keepPending(leftPending)
    let replying = expected->Array.filter(entry => entry.reply !== LeavePending)
    let replies = assignment->Array.mapWithIndex((id, position) => {
      let query = queriesById->Map.get(id)->Option.getOrThrow
      switch (replying->Array.getUnsafe(position)).reply {
      | Respond(response) => (query, Ok(response), true)
      | RespondWith(respond) => (query, Ok(respond(query)), true)
      | RespondUnchecked(response) => (query, Ok(response), false)
      | Fail(exn) => (query, Error(exn), true)
      | LeavePending => JsError.throwWithMessage("A LeavePending entry never takes a reply")
      }
    })
    switch ledger
    ->Ledger.checkReplies(
      replies->Array.map(((query, reply, checked)): Ledger.reply =>
        switch reply {
        | Ok(response) => {
            id: query->queryId,
            checked,
            isFailure: false,
            latestFetchedBlockNumber: ?response.latestFetchedBlockNumber,
            itemBlockNumbers: response.items->Array.map(item => item.blockNumber),
          }
        | Error(_) => {id: query->queryId, checked, isFailure: true, itemBlockNumbers: []}
        }
      ),
    )
    ->Nullable.toOption {
    | Some(message) => JsError.throwWithMessage(message)
    | None => ()
    }
    replies->Array.forEach(((query, reply, _)) =>
      switch reply {
      | Ok(response) => (query->control).respond(response)
      | Error(exn) => (query->control).fail(exn)
      }
    )
  }

  {
    getHeightOrThrowCalls,
    resolveGetHeightOrThrow: height =>
      ledger
      ->Ledger.resolveHeight(height, UserModule.callSite())
      ->settleHeightCalls(answerHeight(height)),
    resolveGetHeightOrThrowAt: (~index, height) =>
      if ledger->Ledger.resolveHeightAt(index) {
        [index]->settleHeightCalls(answerHeight(height))
      },
    setAutoHeight: height =>
      ledger->Ledger.setAutoHeight(height)->settleHeightCalls(answerHeight(height)),
    rejectGetHeightOrThrow: exn =>
      ledger->Ledger.rejectHeights->settleHeightCalls(caller => caller["reject"](exn->Obj.magic)),
    expectHeightCalls: async count => {
      let deadline = realNow() +. 2000.
      let rec awaitCount = async () => {
        await awaitSettled(~deadline)
        let {done, error} = ledger->Ledger.checkHeightCalls(count)
        switch error->Nullable.toOption {
        | Some(message) => JsError.throwWithMessage(message)
        | None =>
          if !done {
            if await nextArrival(~deadline) {
              await awaitCount()
            } else {
              JsError.throwWithMessage(ledger->Ledger.heightCallsTimeoutMessage(count))
            }
          }
        }
      }
      await awaitCount()
    },
    reorgCallCount: () => ledger->Ledger.reorgCallCount,
    pendingItemsQueries,
    expectItemsQueries,
    respondEmptyUpTo: async blockNumber => {
      let rec wave = async (~count) => {
        if count > 1000 {
          JsError.throwWithMessage(
            `respondEmptyUpTo(${blockNumber->Int.toString}) didn't get there in 1000 waves`,
          )
        }
        await expectItemsQueries([
          {where: query => query.fromBlock <= blockNumber, reply: LeavePending},
        ])
        // Every partition answered in this wave has to get there, not just one:
        // a partition behind the others asks again from where it was left. A
        // chunked partition gets there through its last chunk, so it is judged
        // by the furthest of its queries, not by each one.
        let furthestByPartition = Dict.make()
        pendingItemsQueries
        ->Array.copy
        ->Array.forEach(query =>
          if query.fromBlock <= blockNumber {
            let latest = switch query.toBlock {
            | Bounded(toBlock) => Math.Int.min(toBlock, blockNumber)
            | Unbounded => blockNumber
            }
            (query->control).respond({items: [], latestFetchedBlockNumber: latest})
            let furthest = furthestByPartition->Dict.get(query.partitionId)->Option.getOr(0)
            furthestByPartition->Dict.set(query.partitionId, Math.Int.max(furthest, latest))
          }
        )
        let allReached =
          furthestByPartition->Dict.valuesToArray->Array.every(latest => latest === blockNumber)
        if !allReached {
          await wave(~count=count + 1)
        }
      }
      await wave(~count=0)
    },
    drainPendingItemsQueries: (~latestFetchedBlockNumber=?) =>
      ledger
      ->Ledger.drainItemsQueries(latestFetchedBlockNumber->Null.fromOption)
      ->Array.forEach(({id, latestFetchedBlockNumber}) =>
        queriesById
        ->Map.get(id)
        ->Option.forEach(query =>
          (query->control).respond({
            items: [],
            latestFetchedBlockNumber: ?(latestFetchedBlockNumber->Nullable.toOption),
          })
        )
      ),
    getBlockHashesCalls,
    resolveGetBlockHashes: blockHashes =>
      ledger
      ->Ledger.settleAllBlockHashLookups("resolveGetBlockHashes")
      ->settleBlockHashLookups(blockHashes->blockHashesResponse),
    failGetBlockHashes: (exn, ~requestStats=[]) =>
      ledger
      ->Ledger.settleAllBlockHashLookups("failGetBlockHashes")
      ->settleBlockHashLookups({Source.result: Error(exn), requestStats}),
    expectBlockHashLookup: async ({blockNumbers, reply}) => {
      let deadline = realNow() +. 2000.
      let rec awaitLookup = async () => {
        await awaitSettled(~deadline)
        let {status, id, message} = ledger->Ledger.matchBlockHashLookup(blockNumbers)
        let message = () => message->Nullable.toOption->Option.getOr("")
        switch (status, id->Nullable.toOption) {
        | ("matched", Some(id)) => id
        | ("wait", _) =>
          if await nextArrival(~deadline) {
            await awaitLookup()
          } else {
            JsError.throwWithMessage(message())
          }
        | _ => JsError.throwWithMessage(message())
        }
      }
      let id = await awaitLookup()
      [id]->settleBlockHashLookups(reply->blockHashesResponse)
    },
    validateAnswersClaimed: () =>
      switch ledger->Ledger.unclaimedAnswersMessage->Nullable.toOption {
      | Some(message) => JsError.throwWithMessage(message)
      | None => ()
      },
    describeState: () => ledger->Ledger.describeState,
    dropPendingCalls: () => {
      ledger
      ->Ledger.dropPendingCalls
      ->Array.forEach(index => heightCallers->Map.delete(index)->ignore)
      queriesById->Map.clear
      blockHashCallers->Map.clear
      syncPendingQueries()
    },
    heightSubscriptionCalls,
    heightSubscriptionCloseCalls,
    triggerHeightSubscription: height => {
      if !heightSubscriptionUnsubscribed.contents {
        heightSubscriptionCallbacks->Array.forEach(callback => callback(height))
      }
    },
    setHeightSubscriptionStatus: status => {
      if !heightSubscriptionUnsubscribed.contents {
        heightSubscriptionStatusCallbacks->Array.forEach(callback => callback(status))
      }
    },
    unsubscribeHeightSubscription: teardownHeightSubscription,
    source: {
      let source: Source.t = {
        name: "MockSource",
        sourceFor,
        poweredByHyperSync: false,
        chainId,
        pollingInterval,
        getBlockHashes: implement(#getBlockHashes, (~blockNumbers, ~logger as _) => {
          getBlockHashesCalls->Array.push(blockNumbers)->ignore
          let id = ledger->Ledger.takeBlockHashLookup(blockNumbers)
          let promise = Promise.make((resolve, _reject) => blockHashCallers->Map.set(id, resolve))
          notifyArrival()
          promise
        }),
        getHeightOrThrow: implement(#getHeightOrThrow, () => {
          getHeightOrThrowCalls->Array.push(true)->ignore
          notifyArrival()
          let {index, height, failure} = ledger->Ledger.takeHeightCall
          switch (height->Nullable.toOption, failure->Nullable.toOption) {
          | (Some(height), _) => Promise.resolve({Source.height, requestStats: []})
          | (None, Some(message)) =>
            Promise.reject(JsError.make(message)->(Utils.magic: JsError.t => exn))
          | (None, None) =>
            Promise.make((resolve, reject) =>
              heightCallers->Map.set(index, {"resolve": resolve, "reject": reject})
            )
          }
        }),
        getItemsOrThrow: implement(#getItemsOrThrow, (
          ~fromBlock,
          ~toBlock,
          ~addressSet,
          ~includeAllBlocks,
          ~knownHeight,
          ~partitionId,
          ~selection as _,
          ~itemsTarget as _,
          ~retry,
          ~logger as _,
        ) => {
          let id =
            ledger->Ledger.takeItemsQuery(partitionId, fromBlock, toBlock->Null.fromOption, retry)
          let promise = Promise.make((resolve, reject) => {
            let query: pendingItemsQuery = {
              partitionId,
              fromBlock,
              toBlock: switch toBlock {
              | Some(toBlock) => Bounded(toBlock)
              | None => Unbounded
              },
              retryCount: retry,
            }
            let settle = () => {
              ledger->Ledger.settleItemsQuery(id)
              queriesById->Map.delete(id)->ignore
              syncPendingQueries()
            }
            let queryControl = {
              respond: response => {
                settle()
                resolve(makeItemsResponse(response, ~fromBlock, ~toBlock, ~knownHeight))
              },
              fail: exn => {
                settle()
                reject(exn)
              },
            }
            let addresses = addressSet->AddressSet.addressesForTest
            query
            ->Utils.Object.definePropertyWithValue("__id", {enumerable: false, value: id})
            ->Utils.Object.definePropertyWithValue(
              "addresses",
              {enumerable: false, value: addresses},
            )
            ->Utils.Object.definePropertyWithValue(
              "includeAllBlocks",
              {enumerable: false, value: includeAllBlocks},
            )
            ->Utils.Object.definePropertyWithValue(
              "__control",
              {enumerable: false, value: queryControl},
            )
            ->ignore
            queriesById->Map.set(id, query)
            syncPendingQueries()
          })
          notifyArrival()
          promise
        }),
        onReorg: () => ledger->Ledger.recordReorg,
        createHeightSubscription: ?switch methods->Array.includes(#createHeightSubscription) {
        | true =>
          Some(
            (~onHeight, ~onStatus) => {
              heightSubscriptionCalls->Array.push(true)->ignore
              heightSubscriptionCallbacks->Array.push(onHeight)->ignore
              heightSubscriptionStatusCallbacks->Array.push(onStatus)->ignore
              heightSubscriptionUnsubscribed := false
              () => {
                heightSubscriptionCloseCalls->Array.push(true)->ignore
                teardownHeightSubscription()
              }
            },
          )
        | false => None
        },
      }
      setMockSourceState(source, state)
      source
    },
  }
}

// Bounded, so a call that never arrives fails saying what it was waiting for
// rather than as a suite-level timeout.
let waitForCall = async (~arrived, ~message) => {
  let attempts = ref(0)
  while !arrived() && attempts.contents < 3000 {
    attempts := attempts.contents + 1
    await Utils.delay(1)
  }
  if !arrived() {
    JsError.throwWithMessage(`Timed out waiting for ${message}`)
  }
}

// Wait until the source takes a height call beyond the `since`th, for a test
// that can't know how many polls a feed makes while it sleeps out its interval.
// Where the count is known, `expectHeightCalls` checks it exactly.
let waitHeightQuery = (sourceMock: t, ~since) =>
  waitForCall(
    ~arrived=() => sourceMock.getHeightOrThrowCalls->Array.length > since,
    ~message=`a getHeightOrThrow call beyond ${since->Int.toString}`,
  )
