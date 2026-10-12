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
      id: "MockEvent",
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
      ~blockMaskFn=Evm.eventBlockFieldMask,
      ~transactionMaskFn=Evm.eventTransactionFieldMask,
    ),
    resolvedWhere: {topicSelections: [], startBlock: None},
  }: Internal.evmOnEventRegistration :> Internal.onEventRegistration)
}

let defineAddresses: ({..}, array<Address.t>) => unit = %raw(`(payload, addresses) => {
  Object.defineProperty(payload, "addresses", {value: addresses});
}`)

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

module CallPayload = {
  // The partition's addresses as the query carried them, in set order.
  @get external addresses: {..} => array<Address.t> = "addresses"
}

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

// What a test can tell one pending item query from another by.
type itemsQuery = {"fromBlock": int, "toBlock": option<int>, "retry": int, "p": string}

type getItemsOrThrowCall = {
  payload: itemsQuery,
  // Whether the query asked for every block in its range, which the chain only
  // does once it is at the head.
  includeAllBlocks: bool,
  resolve: (
    array<itemMock>,
    ~latestFetchedBlockNumber: int=?,
    ~latestFetchedBlockHash: string=?,
    ~knownHeight: int=?,
    ~prevRangeLastBlock: ReorgDetection.blockData=?,
    ~requestStats: array<Source.requestStat>=?,
  ) => unit,
  reject: 'exn. 'exn => unit,
}

type itemsAnswer = {
  items: array<itemMock>,
  latestFetchedBlockNumber?: int,
  latestFetchedBlockHash?: string,
  knownHeight?: int,
  prevRangeLastBlock?: ReorgDetection.blockData,
  requestStats?: array<Source.requestStat>,
}

type itemsQuerySpec = {
  fromBlock?: int,
  toBlock?: option<int>,
  retry?: int,
  p?: string,
  where?: itemsQuery => bool,
  resolve?: itemsAnswer,
  resolveFrom?: itemsQuery => itemsAnswer,
  reject?: exn,
}

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
  // Answer every height call with `height` from now on, one answer covering any
  // number of polls. A restarted indexer learns the head on its own this way,
  // before the test body gets a chance to resolve anything.
  setAutoHeight: int => unit,
  getItemsOrThrowCalls: array<getItemsOrThrowCall>,
  // How many times the source was told to drop orphaned-chain state.
  reorgCallCount: unit => int,
  // Answers exactly one query. With no query pending yet the answer waits for
  // the next matching one, so a test never has to wait for the indexer to get
  // around to asking. `~filter` is mandatory as soon as more than one pending
  // query matches: item queries fan out one per fetch partition, and answering
  // all of them because the test was written before the partition split is the
  // bug this arity check exists to surface.
  resolveGetItemsOrThrow: (
    array<itemMock>,
    ~filter: itemsQuery => bool=?,
    ~latestFetchedBlockNumber: int=?,
    ~latestFetchedBlockHash: string=?,
    ~knownHeight: int=?,
    ~prevRangeLastBlock: ReorgDetection.blockData=?,
    ~requestStats: array<Source.requestStat>=?,
  ) => unit,
  // Empty-response every matching pending query. A statement about queries that
  // already exist, so unlike `resolveGetItemsOrThrow` it never waits for one.
  drainItemsQueries: (~filter: itemsQuery => bool=?, ~latestFetchedBlockNumber: int=?) => unit,
  interceptGetItemsCalls: array<itemsQuerySpec> => promise<unit>,
  getBlockHashesCalls: array<array<int>>,
  // Answers every block-hash lookup in flight, and throws when there is none.
  // Alone among the resolvers it never waits for its call: the rollback depth
  // search issues several lookups over different block numbers, so an answer
  // registered in advance would land on whichever asked first.
  resolveGetBlockHashes: array<BlockStore.inputBlock> => unit,
  // Throws if a `resolve*` that ran before its call arrived is still waiting for
  // one, naming the call sites. Run at the end of a passing scenario.
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

// The chain chunks a range into one query per partition slice, so a test that
// answers with items at a given block names the slice that covers it.
let coveringBlock = blockNumber =>
  (query: itemsQuery) =>
    query["fromBlock"] <= blockNumber &&
      switch query["toBlock"] {
      | Some(toBlock) => blockNumber <= toBlock
      | None => true
      }

let describeItemsQuery = (query: itemsQuery) =>
  `{p: ${query["p"]}, fromBlock: ${query["fromBlock"]->Int.toString}, toBlock: ${switch query["toBlock"] {
    | Some(toBlock) => toBlock->Int.toString
    | None => "-"
    }}}`

let ambiguousItemsQueries = calls =>
  `resolveGetItemsOrThrow matches ${calls
    ->Array.length
    ->Int.toString} pending queries, so which one it answers is a guess:\n` ++
  calls
  ->Array.map((call: getItemsOrThrowCall) => `  ${call.payload->describeItemsQuery}`)
  ->Array.join(
    "\n",
  ) ++ "\nNarrow it with ~filter, or use drainItemsQueries to empty-response them all."

@val external queueMicrotask: (unit => unit) => unit = "queueMicrotask"

let specMatches = (spec: itemsQuerySpec, call: getItemsOrThrowCall) => {
  let query = call.payload
  spec.fromBlock->Option.mapOr(true, fromBlock => fromBlock === query["fromBlock"]) &&
  spec.toBlock->Option.mapOr(true, toBlock => toBlock == query["toBlock"]) &&
  spec.retry->Option.mapOr(true, retry => retry === query["retry"]) &&
  spec.p->Option.mapOr(true, p => p === query["p"]) &&
  spec.where->Option.mapOr(true, where => where(query))
}

// Every way to give each spec its own pending call, stopping at two: one is
// the answer, two means the specs leave the choice to arrival order.
let specAssignments = (specs: array<itemsQuerySpec>, calls: array<getItemsOrThrowCall>) => {
  let found = []
  let current = []
  let rec assign = index =>
    if found->Array.length < 2 {
      switch specs->Array.get(index) {
      | None => found->Array.push(current->Array.copy)->ignore
      | Some(spec) =>
        calls->Array.forEach(call =>
          if !(current->Array.includes(call)) && spec->specMatches(call) {
            current->Array.push(call)->ignore
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
  | Some(toBlock) => `Some(${toBlock->Int.toString})`
  | None => "None"
  }

// Pasteable as a spec, so a failure's suggestion can go straight into the test.
let describeCallAsSpec = (call: getItemsOrThrowCall, ~fields) => {
  let query = call.payload
  let field = name =>
    switch name {
    | "p" => `p: "${query["p"]}"`
    | "fromBlock" => `fromBlock: ${query["fromBlock"]->Int.toString}`
    | "toBlock" => `toBlock: ${query["toBlock"]->describeToBlock}`
    | _ => `retry: ${query["retry"]->Int.toString}`
    }
  `{${fields->Array.map(field)->Array.join(", ")}}`
}

let allQueryFields = ["p", "fromBlock", "toBlock", "retry"]

let describeSpec = (spec: itemsQuerySpec) => {
  let fields = Array.filterMap(
    [
      spec.p->Option.map(p => `p: "${p}"`),
      spec.fromBlock->Option.map(fromBlock => `fromBlock: ${fromBlock->Int.toString}`),
      spec.toBlock->Option.map(toBlock => `toBlock: ${toBlock->describeToBlock}`),
      spec.retry->Option.map(retry => `retry: ${retry->Int.toString}`),
      spec.where->Option.map(_ => "where: <fn>"),
    ],
    field => field,
  )
  `{${fields->Array.join(", ")}}`
}

let queryField = (call: getItemsOrThrowCall, name) =>
  switch name {
  | "p" => call.payload["p"]
  | "fromBlock" => call.payload["fromBlock"]->Int.toString
  | "toBlock" => call.payload["toBlock"]->describeToBlock
  | _ => call.payload["retry"]->Int.toString
  }

let ambiguousSpecsMessage = (specs: array<itemsQuerySpec>, ~answeringIndices, first, second) => {
  let ambiguousPositions = answeringIndices->Array.reduceWithIndex([], (positions, _, position) => {
    if first->Array.getUnsafe(position) !== second->Array.getUnsafe(position) {
      positions->Array.push(position)->ignore
    }
    positions
  })
  let ambiguousIndices =
    ambiguousPositions->Array.map(position => answeringIndices->Array.getUnsafe(position))
  let calls = []
  ambiguousPositions->Array.forEach(position =>
    [first->Array.getUnsafe(position), second->Array.getUnsafe(position)]->Array.forEach(call =>
      if !(calls->Array.includes(call)) {
        calls->Array.push(call)->ignore
      }
    )
  )
  let distinguishing = allQueryFields->Array.find(name => {
    let values = calls->Array.map(call => call->queryField(name))
    values->Array.every(value => values->Array.indexOf(value) === values->Array.lastIndexOf(value))
  })
  `interceptGetItemsCalls can pair ${ambiguousIndices
    ->Array.map(index =>
      `spec #${index->Int.toString} ${specs->Array.getUnsafe(index)->describeSpec}`
    )
    ->Array.join(", ")} with more than one pending call:\n` ++
  calls
  ->Array.map(call => `  ${call->describeCallAsSpec(~fields=allQueryFields)}`)
  ->Array.join("\n") ++
  switch distinguishing {
  | Some(name) =>
    `\nGive each call its own spec, told apart by ${name}:\n` ++
    calls->Array.map(call => `  ${call->describeCallAsSpec(~fields=[name])}`)->Array.join("\n")
  | None => "\nNo query field tells them apart; tell them apart with `where`, e.g. by addresses."
  }
}

let unclaimedCallsMessage = (unclaimed: array<getItemsOrThrowCall>) =>
  "interceptGetItemsCalls matched every spec, but these pending calls are in no spec:\n" ++
  unclaimed
  ->Array.map(call => `  ${call->describeCallAsSpec(~fields=allQueryFields)}`)
  ->Array.join("\n") ++
  "\nAnswer them in this list, or list them without an answer to leave them in flight:\n" ++
  unclaimed
  ->Array.reduce([], (partitions, call) => {
    if !(partitions->Array.includes(call.payload["p"])) {
      partitions->Array.push(call.payload["p"])->ignore
    }
    partitions
  })
  ->Array.map(p => `  {p: "${p}"}`)
  ->Array.join("\n")

let timeoutMessage = (
  specs: array<itemsQuerySpec>,
  pending: array<getItemsOrThrowCall>,
  ~answering: option<array<getItemsOrThrowCall>>,
  ~isAnswering,
) =>
  `interceptGetItemsCalls timed out. Specs:\n` ++
  specs
  ->Array.mapWithIndex((spec, index) => {
    let matching = pending->Array.filter(call => spec->specMatches(call))
    let reason = switch (matching, answering) {
    | ([], _) => " (matches no pending call)"
    | (_, None) if isAnswering(spec) => " (no call left for it once the other answered specs pick)"
    | (_, Some(answering))
      if !isAnswering(spec) &&
      matching->Array.every(call =>
        answering->Array.includes(call)
      ) => " (every call it matches is taken by an answered spec)"
    | _ => ""
    }
    `  #${index->Int.toString} ${spec->describeSpec}${reason}`
  })
  ->Array.join("\n") ++
  "\nPending calls:\n" ++
  switch pending {
  | [] => "  none"
  | pending =>
    pending
    ->Array.map(call => `  ${call->describeCallAsSpec(~fields=allQueryFields)}`)
    ->Array.join("\n")
  }

let answerCount = (spec: itemsQuerySpec) =>
  [spec.resolve->Option.isSome, spec.resolveFrom->Option.isSome, spec.reject->Option.isSome]
  ->Array.filter(given => given)
  ->Array.length

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
  let getItemsOrThrowCalls = []
  let reorgCalls = ref(0)
  let getBlockHashesCalls = []
  let getBlockHashesResolveFns = []
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

  // Answers registered before their call arrived, consumed in order by the
  // source methods below. `site` is only carried for the end-of-run report.
  let deferredItemsAnswers: array<{
    "site": string,
    "match": getItemsOrThrowCall => bool,
    "respond": getItemsOrThrowCall => unit,
  }> = []
  let deferredHeightAnswers: array<{"site": string, "height": int}> = []

  // Calls a spec matched without answering. They stay pending, but a later
  // list doesn't have to name them again to account for them.
  let seenItemsCalls: array<getItemsOrThrowCall> = []
  let arrivalListeners: array<unit => unit> = []
  let arrivalScheduled = ref(false)
  // A chain issues one query per partition in a single synchronous loop, so
  // listeners are told after a microtask, once the whole fan-out has landed.
  let notifyArrival = () =>
    if !arrivalScheduled.contents {
      arrivalScheduled := true
      queueMicrotask(() => {
        arrivalScheduled := false
        let listeners = arrivalListeners->Array.copy
        arrivalListeners->Utils.Array.clearInPlace
        listeners->Array.forEach(listener => listener())
      })
    }
  let nextArrival = (~deadline) =>
    Promise.make((resolve, _reject) => {
      let timer = setTimeout(
        () => resolve(false),
        Math.max(0., deadline -. Date.now())->Float.toInt,
      )
      arrivalListeners
      ->Array.push(() => {
        clearTimeout(timer)
        resolve(true)
      })
      ->ignore
    })
  // Only a spec with an answer needs a call of its own: which call takes an
  // answer is the one thing arrival order must not decide. A spec without one
  // hands nothing out, so it accounts for every remaining call it matches.
  let rec awaitWave = async (specs, ~answeringIndices, ~deadline) => {
    let answering = answeringIndices->Array.map(index => specs->Array.getUnsafe(index))
    let checking = specs->Array.filter(spec => spec->answerCount === 0)
    let wait = async (~answering) =>
      if await nextArrival(~deadline) {
        await awaitWave(specs, ~answeringIndices, ~deadline)
      } else {
        JsError.throwWithMessage(
          timeoutMessage(specs, getItemsOrThrowCalls, ~answering, ~isAnswering=spec =>
            spec->answerCount === 1
          ),
        )
      }
    switch specAssignments(answering, getItemsOrThrowCalls) {
    | [] => await wait(~answering=None)
    | [assignment] =>
      let remaining =
        getItemsOrThrowCalls->Array.filter(call => !(assignment->Array.includes(call)))
      let checked =
        checking->Array.map(spec => remaining->Array.filter(call => spec->specMatches(call)))
      if checked->Array.some(Utils.Array.isEmpty) {
        await wait(~answering=Some(assignment))
      } else {
        (assignment, checked->Array.flat)
      }
    | ambiguous =>
      JsError.throwWithMessage(
        ambiguousSpecsMessage(
          specs,
          ~answeringIndices,
          ambiguous->Array.getUnsafe(0),
          ambiguous->Array.getUnsafe(1),
        ),
      )
    }
  }

  // With the function we keep only the pending calls,
  // and remove the resolved ones automatically.
  let keepOnlyPendingCalls = (~array, ~fn) => {
    Promise.make((resolve, reject) => {
      let callRef = ref(%raw(`null`))
      callRef :=
        fn(
          ~resolve=arg => {
            resolve(arg)
            let indexOf = array->Array.indexOf(callRef.contents)
            if indexOf !== -1 {
              array->Array.splice(~start=indexOf, ~remove=1, ~insert=[])->ignore
            }
          },
          ~reject=arg => {
            reject(arg)
            let indexOf = array->Array.indexOf(callRef.contents)
            if indexOf !== -1 {
              array->Array.splice(~start=indexOf, ~remove=1, ~insert=[])->ignore
            }
          },
        )
      array->Array.push(callRef.contents)->ignore
    })
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
    getItemsOrThrowCalls,
    reorgCallCount: () => reorgCalls.contents,
    resolveGetItemsOrThrow: (
      items,
      ~filter=?,
      ~latestFetchedBlockNumber=?,
      ~latestFetchedBlockHash=?,
      ~knownHeight=?,
      ~prevRangeLastBlock=?,
      ~requestStats=?,
    ) => {
      let respond = (call: getItemsOrThrowCall) =>
        call.resolve(
          items,
          ~latestFetchedBlockNumber?,
          ~latestFetchedBlockHash?,
          ~knownHeight?,
          ~prevRangeLastBlock?,
          ~requestStats?,
        )
      let matches = (call: getItemsOrThrowCall) =>
        switch filter {
        | Some(filter) => filter(call.payload)
        | None => true
        }
      switch getItemsOrThrowCalls->Array.filter(matches) {
      | [] =>
        deferredItemsAnswers
        ->Array.push({"site": UserModule.callSite(), "match": matches, "respond": respond})
        ->ignore
      | [call] => respond(call)
      | ambiguous => JsError.throwWithMessage(ambiguousItemsQueries(ambiguous))
      }
    },
    drainItemsQueries: (~filter=?, ~latestFetchedBlockNumber=?) => {
      let matches = (call: getItemsOrThrowCall) =>
        switch filter {
        | Some(filter) => filter(call.payload)
        | None => true
        }
      switch getItemsOrThrowCalls->Array.filter(matches) {
      | [] => JsError.throwWithMessage("drainItemsQueries has no pending query to drain")
      | calls => calls->Array.forEach(call => call.resolve([], ~latestFetchedBlockNumber?))
      }
    },
    interceptGetItemsCalls: async specs => {
      specs->Array.forEachWithIndex((spec, index) =>
        if spec->answerCount > 1 {
          JsError.throwWithMessage(
            `interceptGetItemsCalls spec #${index->Int.toString} sets more than one of resolve, resolveFrom and reject`,
          )
        }
      )
      let answeringIndices = specs->Array.reduceWithIndex([], (indices, spec, index) => {
        if spec->answerCount === 1 {
          indices->Array.push(index)->ignore
        }
        indices
      })
      let (assignment, checked) = await awaitWave(
        specs,
        ~answeringIndices,
        ~deadline=Date.now() +. 2000.,
      )
      let unclaimed =
        getItemsOrThrowCalls->Array.filter(call =>
          !(assignment->Array.includes(call)) &&
          !(checked->Array.includes(call)) &&
          !(seenItemsCalls->Array.includes(call))
        )
      if !(unclaimed->Utils.Array.isEmpty) {
        JsError.throwWithMessage(unclaimedCallsMessage(unclaimed))
      }
      checked->Array.forEach(call =>
        if !(seenItemsCalls->Array.includes(call)) {
          seenItemsCalls->Array.push(call)->ignore
        }
      )
      assignment->Array.forEachWithIndex((call, index) => {
        let spec = specs->Array.getUnsafe(answeringIndices->Array.getUnsafe(index))
        let reply = (answer: itemsAnswer) =>
          call.resolve(
            answer.items,
            ~latestFetchedBlockNumber=?answer.latestFetchedBlockNumber,
            ~latestFetchedBlockHash=?answer.latestFetchedBlockHash,
            ~knownHeight=?answer.knownHeight,
            ~prevRangeLastBlock=?answer.prevRangeLastBlock,
            ~requestStats=?answer.requestStats,
          )
        switch (spec.resolve, spec.resolveFrom, spec.reject) {
        | (Some(answer), _, _) => reply(answer)
        | (_, Some(answerFrom), _) => reply(answerFrom(call.payload))
        | (_, _, Some(exn)) => call.reject(exn)
        | (None, None, None) => ()
        }
      })
      let stillPending =
        seenItemsCalls->Array.filter(call => getItemsOrThrowCalls->Array.includes(call))
      seenItemsCalls->Utils.Array.clearInPlace
      seenItemsCalls->Array.pushMany(stillPending)
    },
    getBlockHashesCalls,
    resolveGetBlockHashes: blockHashes => {
      let blockStore = BlockStore.fromJs(
        blockHashes->Array.map((block): BlockStore.inputBlock => {
          ...block,
          blockHash: ?(block.blockHash->Option.map(evmBlockHash)),
        }),
        ~ecosystem=Evm,
      )
      if getBlockHashesResolveFns->Utils.Array.isEmpty {
        JsError.throwWithMessage("getBlockHashesResolveFns is empty")
      }
      let response = {Source.result: Ok(blockStore), requestStats: []}
      getBlockHashesResolveFns->Array.forEach(resolve => resolve(response))
      getBlockHashesResolveFns->Utils.Array.clearInPlace
    },
    validateAnswersClaimed: () =>
      switch Array.flat([
        deferredItemsAnswers->Array.map(answer => `resolveGetItemsOrThrow at ${answer["site"]}`),
        deferredHeightAnswers->Array.map(answer => `resolveGetHeightOrThrow at ${answer["site"]}`),
      ]) {
      | [] => ()
      | unclaimed =>
        JsError.throwWithMessage(
          `Chain ${chainId->ChainId.toString} registered these mock answers before their call ` ++
          "arrived, and no call ever claimed them:\n" ++
          unclaimed->Array.map(entry => `  ${entry}`)->Array.join("\n"),
        )
      },
    dropPendingCalls: () => {
      getItemsOrThrowCalls->Utils.Array.clearInPlace
      seenItemsCalls->Utils.Array.clearInPlace
      pendingHeightCallIndices()->Array.forEach(index =>
        getHeightOrThrowPending->Array.set(index, None)
      )
      getBlockHashesResolveFns->Utils.Array.clearInPlace
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
          Promise.make((resolve, _reject) => {
            getBlockHashesResolveFns->Array.push(resolve)->ignore
          })
        }),
        getHeightOrThrow: implement(#getHeightOrThrow, () => {
          getHeightOrThrowCalls->Array.push(true)->ignore
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
          let promise = keepOnlyPendingCalls(~array=getItemsOrThrowCalls, ~fn=(
            ~resolve,
            ~reject,
          ) => {
            let payload = {
              "fromBlock": fromBlock,
              "toBlock": toBlock,
              "retry": retry,
              "p": partitionId,
            }
            // Non-enumerable so it stays out of `toEqual` comparisons of the
            // payload while remaining inspectable from a test.
            payload->defineAddresses(addressSet->AddressSet.addressesForTest)
            {
              payload,
              includeAllBlocks,
              resolve: (
                items,
                ~latestFetchedBlockNumber=?,
                ~latestFetchedBlockHash=?,
                ~knownHeight=knownHeight,
                ~prevRangeLastBlock=?,
                ~requestStats=[],
              ) => {
                let latestFetchedBlockNumber =
                  latestFetchedBlockNumber->Option.getOr(toBlock->Option.getOr(fromBlock))

                // The store takes 32-byte hashes, so widen the decimal marker.
                let mockBlockHash = blockNumber => evmBlockHash(`0x${blockNumber->Int.toString}`)
                let latestFetchedBlockHash = switch latestFetchedBlockHash {
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
                let prevEntry = switch prevRangeLastBlock {
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
                // A real source returns the header of every block a matched
                // item came from, so those blocks carry a hash and a timestamp
                // too. Without them the store only ever learns the range's seam
                // and end, and reorg detection never sees the blocks events
                // landed on.
                items->Array.forEach(
                  item => {
                    if !(observedBlocks->Array.some(b => b.blockNumber === item.blockNumber)) {
                      observedBlocks->Array.push({
                        blockNumber: item.blockNumber,
                        blockHash: mockBlockHash(item.blockNumber),
                        blockTimestamp: item.blockNumber,
                      })
                    }
                  },
                )
                let responseBlockStore = BlockStore.make(~ecosystem=Evm)
                observedBlocks->Array.forEach(
                  block => {
                    let page = BlockStore.fromJs([block], ~ecosystem=Evm)
                    responseBlockStore->BlockStore.appendPage(page)
                  },
                )
                resolve({
                  Source.knownHeight,
                  parsedQueueItems: items->Array.map(
                    item => {
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
                          (
                            "hash",
                            `0x${item.blockNumber->Int.toString}`->(Utils.magic: string => unknown),
                          ),
                        ])
                        ->Dict.assign(item.blockFields->Option.getOr(Dict.make()))
                        ->(Utils.magic: dict<unknown> => Internal.eventBlock),
                        transaction: ?(
                          item.transactionFields->Option.map(
                            fields =>
                              fields->(Utils.magic: dict<unknown> => Internal.eventTransaction),
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
                    },
                  ),
                  transactionStore: None,
                  blockStore: responseBlockStore,
                  latestFetchedBlockNumber,
                  stats: {
                    totalTimeElapsed: 0.,
                  },
                  requestStats,
                })
              },
              reject: reject->Utils.magic,
            }
          })
          notifyArrival()
          switch getItemsOrThrowCalls->Array.at(-1) {
          | Some(call) =>
            switch deferredItemsAnswers->Array.findIndex(answer => answer["match"](call)) {
            | -1 => ()
            | index =>
              let answer = deferredItemsAnswers->Array.getUnsafe(index)
              deferredItemsAnswers->Array.splice(~start=index, ~remove=1, ~insert=[])->ignore
              answer["respond"](call)
            }
          | None => ()
          }
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

// Wait until the source takes a height call beyond the `since`th. A feed polls
// and then sleeps out its interval, so a test that wants to answer the *next*
// poll has to wait for it to be made: resolving while none is outstanding
// settles nothing, silently, and leaves the height where it was.
let waitHeightQuery = (sourceMock: t, ~since) =>
  waitForCall(
    ~arrived=() => sourceMock.getHeightOrThrowCalls->Array.length > since,
    ~message=`a getHeightOrThrow call beyond ${since->Int.toString}`,
  )

// Wait until the source has a pending getItemsOrThrow call. Queries are
// serialized by the cross-chain budget waterfall, so a chain's query only
// appears after the more-behind chains' responses release the budget.
let waitItemsQuery = (sourceMock: t) =>
  waitForCall(
    ~arrived=() => sourceMock.getItemsOrThrowCalls->Array.length > 0,
    ~message="a getItemsOrThrow call",
  )

let interceptGetItemsCalls = (mock: t, specs) => mock.interceptGetItemsCalls(specs)
