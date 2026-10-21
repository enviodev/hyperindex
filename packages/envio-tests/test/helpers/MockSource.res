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
      Promise.resolve()
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
        ~blockMaskFn=Evm.blockFieldMask,
        ~transactionMaskFn=Evm.transactionFieldMask,
      ),
      sighash: "",
      topicCount: 1,
      paramsMetadata: [],
    }: Internal.evmEventConfig :> Internal.eventConfig),
    isWildcard,
    filterByAddresses: false,
    dependsOnAddresses: !isWildcard,
    addressFilterParamGroups: [],
    startBlock: None,
    handler: Some(handler),
    contractRegister: Some(contractRegister),
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.make(),
      ~transactionFields=Utils.Set.make(),
      ~blockMaskFn=Evm.blockFieldMask,
      ~transactionMaskFn=Evm.transactionFieldMask,
    ),
    resolvedWhere: {topicSelections: [], startBlock: None},
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
    if !(sourceStates->Utils.Array.isEmpty) {
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
        ~contractName=switch chainConfig.contracts->Array.get(0) {
        | Some(contract) => contract.name
        | None => "MockContract"
        },
      )
      registrations.onEventRegistrations->Array.push(mockRegistration)->ignore
      sourceStates->Array.forEach(state => state.onEventRegistrationRef := Some(mockRegistration))
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
  contractRegister?: mockSourceContractRegister,
  // Laid over the number, timestamp and hash every item's block carries.
  blockFields?: dict<unknown>,
  transactionFields?: dict<unknown>,
}

// Unboxed so a failed `toEqual` prints `100` or `"unbounded"`, not a tagged object.
@unboxed type toBlock = Bounded(int) | @as("unbounded") Unbounded

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

let describeBlockNumbers = blockNumbers =>
  `[${blockNumbers->Array.map(blockNumber => blockNumber->Int.toString)->Array.join(", ")}]`

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

let queryCoversBlock = (query: pendingItemsQuery, blockNumber) =>
  query.fromBlock <= blockNumber &&
    switch query.toBlock {
    | Bounded(toBlock) => blockNumber <= toBlock
    | Unbounded => true
    }

let expectedMatches = (expected: expectedItemsQuery, query: pendingItemsQuery) =>
  expected.partitionId->Option.mapOr(true, partitionId => partitionId === query.partitionId) &&
  expected.fromBlock->Option.mapOr(true, fromBlock => fromBlock === query.fromBlock) &&
  expected.toBlock->Option.mapOr(true, toBlock => toBlock == query.toBlock) &&
  expected.retryCount->Option.mapOr(true, retryCount => retryCount === query.retryCount) &&
  expected.coversBlock->Option.mapOr(true, blockNumber => query->queryCoversBlock(blockNumber)) &&
  expected.where->Option.mapOr(true, where => where(query))

let isReplying = (expected: expectedItemsQuery) =>
  switch expected.reply {
  | Respond(_) | RespondWith(_) | RespondUnchecked(_) | Fail(_) => true
  | LeavePending => false
  }

// Every way to give each replying entry its own pending query, stopping at two:
// one is the answer, two means the list leaves the choice to arrival order.
let replyAssignments = (expected: array<expectedItemsQuery>, queries: array<pendingItemsQuery>) => {
  let found = []
  let current = []
  let rec assign = index =>
    if found->Array.length < 2 {
      switch expected->Array.get(index) {
      | None => found->Array.push(current->Array.copy)->ignore
      | Some(entry) =>
        queries->Array.forEach(query =>
          if !(current->Array.includes(query)) && entry->expectedMatches(query) {
            current->Array.push(query)->ignore
            assign(index + 1)
            current->Array.pop->ignore
          }
        )
      }
    }
  assign(0)
  found
}

let describeToBlock = toBlock =>
  switch toBlock {
  | Bounded(toBlock) => `Bounded(${toBlock->Int.toString})`
  | Unbounded => "Unbounded"
  }

let queryFields = ["partitionId", "fromBlock", "toBlock", "retryCount"]

let queryField = (query: pendingItemsQuery, name) =>
  switch name {
  | "partitionId" => `"${query.partitionId}"`
  | "fromBlock" => query.fromBlock->Int.toString
  | "toBlock" => query.toBlock->describeToBlock
  | _ => query.retryCount->Int.toString
  }

// Pasteable as an entry, so a failure's suggestion can go straight into the test.
let describeQuery = (query: pendingItemsQuery, ~fields=queryFields, ~reply=?) =>
  `{${fields
    ->Array.map(name => `${name}: ${query->queryField(name)}`)
    ->Array.concat(
      switch reply {
      | Some(reply) => [`reply: ${reply}`]
      | None => []
      },
    )
    ->Array.join(", ")}}`

let describeExpected = (expected: expectedItemsQuery) =>
  `{${Array.filterMap(
      [
        expected.partitionId->Option.map(partitionId => `partitionId: "${partitionId}"`),
        expected.fromBlock->Option.map(fromBlock => `fromBlock: ${fromBlock->Int.toString}`),
        expected.toBlock->Option.map(toBlock => `toBlock: ${toBlock->describeToBlock}`),
        expected.retryCount->Option.map(retryCount => `retryCount: ${retryCount->Int.toString}`),
        expected.coversBlock->Option.map(blockNumber =>
          `coversBlock: ${blockNumber->Int.toString}`
        ),
        expected.where->Option.map(_ => "where: <fn>"),
        Some(
          `reply: ${switch expected.reply {
            | Respond(_) => "Respond(…)"
            | RespondWith(_) => "RespondWith(…)"
            | RespondUnchecked(_) => "RespondUnchecked(…)"
            | Fail(_) => "Fail(…)"
            | LeavePending => "LeavePending"
            }}`,
        ),
      ],
      field => field,
    )->Array.join(", ")}}`

let describeQueries = queries =>
  switch queries {
  | [] => "  none"
  | queries => queries->Array.map(query => `  ${query->describeQuery}`)->Array.join("\n")
  }

let ambiguousRepliesMessage = (
  expected: array<expectedItemsQuery>,
  ~replyingIndices,
  first,
  second,
) => {
  let positions = replyingIndices->Array.reduceWithIndex([], (positions, _, position) => {
    if first->Array.getUnsafe(position) !== second->Array.getUnsafe(position) {
      positions->Array.push(position)->ignore
    }
    positions
  })
  let queries = []
  positions->Array.forEach(position =>
    [first->Array.getUnsafe(position), second->Array.getUnsafe(position)]->Array.forEach(query =>
      if !(queries->Array.includes(query)) {
        queries->Array.push(query)->ignore
      }
    )
  )
  let distinguishing = queryFields->Array.find(name => {
    let values = queries->Array.map(query => query->queryField(name))
    values->Array.every(value => values->Array.indexOf(value) === values->Array.lastIndexOf(value))
  })
  `expectItemsQueries can reply to more than one pending query with ${positions
    ->Array.map(position => {
      let index = replyingIndices->Array.getUnsafe(position)
      `entry #${index->Int.toString} ${expected->Array.getUnsafe(index)->describeExpected}`
    })
    ->Array.join(", ")}:\n` ++
  queries->describeQueries ++
  switch distinguishing {
  | Some(name) =>
    `\nGive each query its own entry, told apart by ${name}:\n` ++
    queries
    ->Array.map(query => `  ${query->describeQuery(~fields=[name], ~reply="…")}`)
    ->Array.join("\n")
  | None => "\nNo query field tells them apart; tell them apart with `where`, e.g. by addresses."
  }
}

let unlistedQueriesMessage = (unlisted: array<pendingItemsQuery>) =>
  "expectItemsQueries matched every entry, but these pending queries are in none:\n" ++
  unlisted->describeQueries ++
  "\nReply to them in this list, or keep them pending:\n" ++
  unlisted
  ->Array.reduce([], (partitionIds, query) => {
    if !(partitionIds->Array.includes(query.partitionId)) {
      partitionIds->Array.push(query.partitionId)->ignore
    }
    partitionIds
  })
  ->Array.map(partitionId => `  {partitionId: "${partitionId}", reply: LeavePending}`)
  ->Array.join("\n")

let timeoutMessage = (
  expected: array<expectedItemsQuery>,
  pending: array<pendingItemsQuery>,
  ~replied: option<array<pendingItemsQuery>>,
) =>
  "expectItemsQueries timed out. Expected:\n" ++
  expected
  ->Array.mapWithIndex((entry, index) => {
    let matching = pending->Array.filter(query => entry->expectedMatches(query))
    let reason = switch (matching, replied) {
    | ([], _) => " (matches no pending query)"
    | (_, None) if entry->isReplying => " (no query left for it once the other replies pick)"
    | (_, Some(replied))
      if !isReplying(entry) &&
      matching->Array.every(query =>
        replied->Array.includes(query)
      ) => " (every query it matches is taken by a reply)"
    | _ => ""
    }
    `  #${index->Int.toString} ${entry->describeExpected}${reason}`
  })
  ->Array.join("\n") ++
  "\nPending:\n" ++
  pending->describeQueries

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
) => {
  let implement = (method: method, fn) => {
    if methods->Array.includes(method) {
      fn
    } else {
      (() => JsError.throwWithMessage(`source.${(method :> string)} not implemented`))->Obj.magic
    }
  }

  let chainId = chainId->ChainId.fromInt
  let getHeightOrThrowCalls = []
  // One entry per call the source has taken, in the order it took them, so an
  // index here is the call number a test counted. `None` is a call that has
  // already been answered — including one a standing height answered on the
  // spot, which never parks anything — which is what makes answering the same
  // call twice do nothing.
  let getHeightOrThrowPending: array<
    option<{
      "resolve": Source.getHeightResponse => unit,
      "reject": exn => unit,
    }>,
  > = []
  let settleHeightCall = (index, answer) =>
    switch getHeightOrThrowPending->Array.get(index) {
    | Some(Some(pending)) =>
      getHeightOrThrowPending->Array.set(index, None)
      answer(pending)
    | Some(None) | None => ()
    }
  let pendingHeightCallIndices = () =>
    getHeightOrThrowPending->Array.reduceWithIndex([], (indices, pending, index) => {
      switch pending {
      | Some(_) => indices->Array.push(index)->ignore
      | None => ()
      }
      indices
    })
  let reorgCalls = ref(0)
  let getBlockHashesCalls = []
  let pendingBlockHashLookups = []
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
  let autoHeight = ref(autoHeight)
  let state: mockSourceState = {onEventRegistrationRef: ref(None), isWildcard}

  // Height answers registered before their call arrived, consumed in order by
  // `getHeightOrThrow`. `site` is only carried for the end-of-run report.
  let deferredHeightAnswers: array<{"site": string, "height": int}> = []

  let pendingItemsQueries: array<pendingItemsQuery> = []
  // Queries an earlier `expectItemsQueries` left pending. A later list doesn't
  // have to name them again to account for them.
  let keptPendingQueries: array<pendingItemsQuery> = []
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
  // Only a reply needs a query of its own: which query takes a reply is the one
  // thing arrival order must not decide. `LeavePending` hands nothing out, so
  // it accounts for every remaining query it matches.
  let rec awaitMatch = async (expected, ~replyingIndices, ~deadline) => {
    // A wave still landing would have its first query taken for all of it.
    if settling.contents {
      let _ = await nextArrival(~deadline)
    }
    let replying = replyingIndices->Array.map(index => expected->Array.getUnsafe(index))
    let leavingPending = expected->Array.filter(entry => !isReplying(entry))
    let wait = async (~replied) =>
      if await nextArrival(~deadline) {
        await awaitMatch(expected, ~replyingIndices, ~deadline)
      } else {
        JsError.throwWithMessage(timeoutMessage(expected, pendingItemsQueries, ~replied))
      }
    switch replyAssignments(replying, pendingItemsQueries) {
    | [] => await wait(~replied=None)
    | [assignment] =>
      let remaining =
        pendingItemsQueries->Array.filter(query => !(assignment->Array.includes(query)))
      let leftPending =
        leavingPending->Array.map(entry =>
          remaining->Array.filter(query => entry->expectedMatches(query))
        )
      if leftPending->Array.some(Utils.Array.isEmpty) {
        await wait(~replied=Some(assignment))
      } else {
        (assignment, leftPending->Array.flat)
      }
    | ambiguous =>
      JsError.throwWithMessage(
        ambiguousRepliesMessage(
          expected,
          ~replyingIndices,
          ambiguous->Array.getUnsafe(0),
          ambiguous->Array.getUnsafe(1),
        ),
      )
    }
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
    let replyingIndices = expected->Array.reduceWithIndex([], (indices, entry, index) => {
      if entry->isReplying {
        indices->Array.push(index)->ignore
      }
      indices
    })
    let (assignment, leftPending) = await awaitMatch(
      expected,
      ~replyingIndices,
      ~deadline=realNow() +. 2000.,
    )
    let unlisted =
      pendingItemsQueries->Array.filter(query =>
        !(assignment->Array.includes(query)) &&
        !(leftPending->Array.includes(query)) &&
        !(keptPendingQueries->Array.includes(query))
      )
    if !(unlisted->Utils.Array.isEmpty) {
      JsError.throwWithMessage(unlistedQueriesMessage(unlisted))
    }
    leftPending->Array.forEach(query =>
      if !(keptPendingQueries->Array.includes(query)) {
        keptPendingQueries->Array.push(query)->ignore
      }
    )
    let replies = assignment->Array.mapWithIndex((query, position) =>
      switch (expected->Array.getUnsafe(replyingIndices->Array.getUnsafe(position))).reply {
      | Respond(response) => (query, Ok(response), true)
      | RespondWith(respond) => (query, Ok(respond(query)), true)
      | RespondUnchecked(response) => (query, Ok(response), false)
      | Fail(exn) => (query, Error(exn), true)
      | LeavePending => JsError.throwWithMessage("A LeavePending entry never takes a reply")
      }
    )
    replies->Array.forEach(((query, reply, checked)) =>
      switch (reply, query.toBlock) {
      | _ if !checked => ()
      | (Ok({latestFetchedBlockNumber}), Bounded(toBlock)) if latestFetchedBlockNumber > toBlock =>
        JsError.throwWithMessage(
          `expectItemsQueries can't reply latestFetchedBlockNumber ${latestFetchedBlockNumber->Int.toString} to ${query->describeQuery}: a source never fetches past the toBlock it was asked for`,
        )
      | (Ok(response), _) =>
        let latest = response.latestFetchedBlockNumber->Option.getOr(
          switch query.toBlock {
          | Bounded(toBlock) => toBlock
          | Unbounded => query.fromBlock
          },
        )
        switch response.items->Array.find(item =>
          item.blockNumber < query.fromBlock || item.blockNumber > latest
        ) {
        | Some(item) =>
          JsError.throwWithMessage(
            `expectItemsQueries can't reply an item at block ${item.blockNumber->Int.toString} to ${query->describeQuery}: a source only returns items between the query's fromBlock and the latestFetchedBlockNumber it replies (${latest->Int.toString})`,
          )
        | None => ()
        }
      | _ => ()
      }
    )
    replies->Array.forEach(((query, reply, _)) =>
      switch reply {
      | Ok(response) => (query->control).respond(response)
      | Error(exn) => (query->control).fail(exn)
      }
    )
  }

  {
    getHeightOrThrowCalls,
    resolveGetHeightOrThrow: height => {
      switch pendingHeightCallIndices() {
      | [] =>
        deferredHeightAnswers->Array.push({"site": UserModule.callSite(), "height": height})->ignore
      | indices =>
        indices->Array.forEach(index =>
          index->settleHeightCall(pending => pending["resolve"]({Source.height, requestStats: []}))
        )
      }
    },
    resolveGetHeightOrThrowAt: (~index, height) =>
      if index >= getHeightOrThrowCalls->Array.length || index < 0 {
        JsError.throwWithMessage(
          `The source has taken no getHeightOrThrow call at index ${index->Int.toString}`,
        )
      } else {
        index->settleHeightCall(pending => pending["resolve"]({Source.height, requestStats: []}))
      },
    setAutoHeight: height => {
      autoHeight := Some(height)
      // A standing answer supersedes one parked for a single call.
      deferredHeightAnswers->Utils.Array.clearInPlace
      pendingHeightCallIndices()->Array.forEach(index =>
        index->settleHeightCall(pending => pending["resolve"]({Source.height, requestStats: []}))
      )
    },
    rejectGetHeightOrThrow: exn =>
      pendingHeightCallIndices()->Array.forEach(index =>
        index->settleHeightCall(pending => pending["reject"](exn->Obj.magic))
      ),
    expectHeightCalls: async count => {
      let deadline = realNow() +. 2000.
      let rec awaitCount = async () => {
        // A burst still landing would be counted short of its excess call.
        if settling.contents {
          let _ = await nextArrival(~deadline)
        }
        let taken = getHeightOrThrowCalls->Array.length
        if taken > count {
          JsError.throwWithMessage(
            `expectHeightCalls expected ${count->Int.toString} height calls, but the source has taken ${taken->Int.toString}`,
          )
        } else if taken < count {
          if await nextArrival(~deadline) {
            await awaitCount()
          } else {
            JsError.throwWithMessage(
              `expectHeightCalls timed out waiting for ${count->Int.toString} height calls; the source has taken ${taken->Int.toString}`,
            )
          }
        }
      }
      await awaitCount()
    },
    reorgCallCount: () => reorgCalls.contents,
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
      switch pendingItemsQueries->Array.copy {
      | [] => JsError.throwWithMessage("drainPendingItemsQueries has no pending query to drain")
      | queries =>
        queries->Array.forEach(query =>
          switch (latestFetchedBlockNumber, query.toBlock) {
          | (Some(latest), Bounded(toBlock)) if latest > toBlock =>
            JsError.throwWithMessage(
              `drainPendingItemsQueries can't reply latestFetchedBlockNumber ${latest->Int.toString} to ${query->describeQuery}: a source never fetches past the toBlock it was asked for. Drain without ~latestFetchedBlockNumber to answer each query up to its own toBlock.`,
            )
          | _ => ()
          }
        )
        queries->Array.forEach(query =>
          (query->control).respond({items: [], ?latestFetchedBlockNumber})
        )
      },
    getBlockHashesCalls,
    resolveGetBlockHashes: blockHashes => {
      if pendingBlockHashLookups->Utils.Array.isEmpty {
        JsError.throwWithMessage("resolveGetBlockHashes has no pending lookup to answer")
      }
      let response = blockHashes->blockHashesResponse
      let lookups = pendingBlockHashLookups->Array.copy
      pendingBlockHashLookups->Utils.Array.clearInPlace
      lookups->Array.forEach(lookup => lookup["resolve"](response))
    },
    expectBlockHashLookup: async ({blockNumbers, reply}) => {
      let deadline = realNow() +. 2000.
      let rec awaitLookup = async () => {
        // A burst still landing would have its first lookup answered alone.
        if settling.contents {
          let _ = await nextArrival(~deadline)
        }
        switch pendingBlockHashLookups {
        | [] =>
          if await nextArrival(~deadline) {
            await awaitLookup()
          } else {
            JsError.throwWithMessage(
              `expectBlockHashLookup timed out waiting for a lookup of ${blockNumbers->describeBlockNumbers}. No lookup is pending.`,
            )
          }
        | [lookup] if lookup["blockNumbers"] == blockNumbers => lookup
        | [lookup] =>
          JsError.throwWithMessage(
            `expectBlockHashLookup expected a lookup of ${blockNumbers->describeBlockNumbers}, but the pending lookup asks for ${lookup["blockNumbers"]->describeBlockNumbers}`,
          )
        | lookups =>
          JsError.throwWithMessage(
            `expectBlockHashLookup can't tell which of ${lookups
              ->Array.length
              ->Int.toString} pending lookups to answer: ${lookups
              ->Array.map(lookup => lookup["blockNumbers"]->describeBlockNumbers)
              ->Array.join(", ")}`,
          )
        }
      }
      let lookup = await awaitLookup()
      pendingBlockHashLookups
      ->Array.splice(~start=pendingBlockHashLookups->Array.indexOf(lookup), ~remove=1, ~insert=[])
      ->ignore
      lookup["resolve"](reply->blockHashesResponse)
    },
    validateAnswersClaimed: () =>
      switch deferredHeightAnswers->Array.map(answer =>
        `resolveGetHeightOrThrow at ${answer["site"]}`
      ) {
      | [] => ()
      | unclaimed =>
        JsError.throwWithMessage(
          `Chain ${chainId->ChainId.toString} registered these mock answers before their call ` ++
          "arrived, and no call ever claimed them:\n" ++
          unclaimed->Array.map(entry => `  ${entry}`)->Array.join("\n"),
        )
      },
    describeState: () =>
      `Mock source for chain ${chainId->ChainId.toString} at the failure:\n` ++
      "  pending item queries:" ++
      switch pendingItemsQueries {
      | [] => " none"
      | queries => queries->Array.map(query => `\n    ${query->describeQuery}`)->Array.join("")
      } ++
      "\n  pending block-hash lookups: " ++
      switch pendingBlockHashLookups {
      | [] => "none"
      | lookups =>
        lookups->Array.map(lookup => lookup["blockNumbers"]->describeBlockNumbers)->Array.join(", ")
      } ++
      `\n  height calls taken: ${getHeightOrThrowCalls->Array.length->Int.toString}`,
    dropPendingCalls: () => {
      pendingItemsQueries->Utils.Array.clearInPlace
      keptPendingQueries->Utils.Array.clearInPlace
      pendingHeightCallIndices()->Array.forEach(index =>
        getHeightOrThrowPending->Array.set(index, None)
      )
      pendingBlockHashLookups->Utils.Array.clearInPlace
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
          let promise = Promise.make((resolve, _reject) => {
            pendingBlockHashLookups
            ->Array.push({"blockNumbers": blockNumbers, "resolve": resolve})
            ->ignore
          })
          notifyArrival()
          promise
        }),
        getHeightOrThrow: implement(#getHeightOrThrow, () => {
          getHeightOrThrowCalls->Array.push(true)->ignore
          notifyArrival()
          // Pushed for every call, answered or not, so the two arrays stay the
          // same length and an index means the same thing in both.
          let answered = height => {
            getHeightOrThrowPending->Array.push(None)->ignore
            Promise.resolve({Source.height, requestStats: []})
          }
          switch autoHeight.contents {
          | Some(height) => answered(height)
          | None =>
            switch deferredHeightAnswers->Array.shift {
            | Some(answer) => answered(answer["height"])
            | None =>
              Promise.make((resolve, reject) => {
                getHeightOrThrowPending
                ->Array.push(Some({"resolve": resolve, "reject": reject}))
                ->ignore
              })
            }
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
              [pendingItemsQueries, keptPendingQueries]->Array.forEach(
                queries =>
                  switch queries->Array.indexOf(query) {
                  | -1 => ()
                  | index => queries->Array.splice(~start=index, ~remove=1, ~insert=[])->ignore
                  },
              )
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
            pendingItemsQueries->Array.push(query)->ignore
          })
          notifyArrival()
          promise
        }),
        onReorg: () => reorgCalls := reorgCalls.contents + 1,
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
