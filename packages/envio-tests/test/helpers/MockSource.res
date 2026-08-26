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
let makeMockSourceRegistration = (~index, ~contractName, ~isWildcard): Internal.onEventRegistration => {
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
}

// What a test can tell one pending item query from another by.
type itemsQuery = {"fromBlock": int, "toBlock": option<int>, "retry": int, "p": string}

type getItemsOrThrowCall = {
  payload: itemsQuery,
  resolve: (
    array<itemMock>,
    ~latestFetchedBlockNumber: int=?,
    ~latestFetchedBlockHash: string=?,
    ~knownHeight: int=?,
    ~prevRangeLastBlock: ReorgDetection.blockData=?,
  ) => unit,
  reject: 'exn. 'exn => unit,
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
  ) => unit,
  // Empty-response every matching pending query. A statement about queries that
  // already exist, so unlike `resolveGetItemsOrThrow` it never waits for one.
  drainItemsQueries: (~filter: itemsQuery => bool=?, ~latestFetchedBlockNumber: int=?) => unit,
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
  triggerHeightSubscription: int => unit,
  unsubscribeHeightSubscription: unit => unit,
}

// The chain chunks a range into one query per partition slice, so a test that
// answers with items at a given block names the slice that covers it.
let coveringBlock = blockNumber => (query: itemsQuery) =>
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
  calls->Array.map((call: getItemsOrThrowCall) =>
    `  ${call.payload->describeItemsQuery}`
  )->Array.join("\n") ++
  "\nNarrow it with ~filter, or use drainItemsQueries to empty-response them all."

let make = (
  methods: array<method>,
  ~chainId=1,
  ~sourceFor=Source.Sync,
  ~pollingInterval=1000,
  ~isWildcard=false,
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
  let getHeightOrThrowResolveFns = []
  let getHeightOrThrowRejectFns = []
  let getItemsOrThrowCalls = []
  let reorgCalls = ref(0)
  let getBlockHashesCalls = []
  let getBlockHashesResolveFns = []
  // Height subscription state
  let heightSubscriptionCalls = []
  let heightSubscriptionCallbacks: array<int => unit> = []
  let heightSubscriptionUnsubscribed = ref(false)
  let autoHeight = ref(None)
  let state: mockSourceState = {onEventRegistrationRef: ref(None), isWildcard}

  // Answers registered before their call arrived, consumed in order by the
  // source methods below. `site` is only carried for the end-of-run report.
  let deferredItemsAnswers: array<{"site": string, "match": getItemsOrThrowCall => bool, "respond": getItemsOrThrowCall => unit}> = []
  let deferredHeightAnswers: array<{"site": string, "height": int}> = []

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
      if getHeightOrThrowResolveFns->Utils.Array.isEmpty {
        deferredHeightAnswers->Array.push({"site": UserModule.callSite(), "height": height})->ignore
      } else {
        getHeightOrThrowResolveFns->Array.forEach(resolve =>
          resolve({Source.height, requestStats: []})
        )
        getHeightOrThrowResolveFns->Utils.Array.clearInPlace
        getHeightOrThrowRejectFns->Utils.Array.clearInPlace
      }
    },
    setAutoHeight: height => {
      autoHeight := Some(height)
      // A standing answer supersedes one parked for a single call.
      deferredHeightAnswers->Utils.Array.clearInPlace
      getHeightOrThrowResolveFns->Array.forEach(resolve =>
        resolve({Source.height, requestStats: []})
      )
      getHeightOrThrowResolveFns->Utils.Array.clearInPlace
    },
    rejectGetHeightOrThrow: exn => {
      getHeightOrThrowRejectFns->Array.forEach(reject => reject(exn->Obj.magic))
    },
    getItemsOrThrowCalls,
    reorgCallCount: () => reorgCalls.contents,
    resolveGetItemsOrThrow: (
      items,
      ~filter=?,
      ~latestFetchedBlockNumber=?,
      ~latestFetchedBlockHash=?,
      ~knownHeight=?,
      ~prevRangeLastBlock=?,
    ) => {
      let respond = (call: getItemsOrThrowCall) =>
        call.resolve(
          items,
          ~latestFetchedBlockNumber?,
          ~latestFetchedBlockHash?,
          ~knownHeight?,
          ~prevRangeLastBlock?,
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
    getBlockHashesCalls,
    resolveGetBlockHashes: blockHashes => {
      let blockStore = BlockStore.fromJs(
        blockHashes->Array.map((block): BlockStore.inputBlock => {
          ...block,
          blockHash: ?block.blockHash->Option.map(evmBlockHash),
        }),
        ~ecosystem=Evm,
        ~shouldChecksum=false,
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
      getHeightOrThrowResolveFns->Utils.Array.clearInPlace
      getHeightOrThrowRejectFns->Utils.Array.clearInPlace
      getBlockHashesResolveFns->Utils.Array.clearInPlace
    },
    heightSubscriptionCalls,
    triggerHeightSubscription: height => {
      if !heightSubscriptionUnsubscribed.contents {
        heightSubscriptionCallbacks->Array.forEach(callback => callback(height))
      }
    },
    unsubscribeHeightSubscription: () => {
      heightSubscriptionUnsubscribed := true
      heightSubscriptionCallbacks->Utils.Array.clearInPlace
    },
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
          switch autoHeight.contents {
          | Some(height) => Promise.resolve({Source.height, requestStats: []})
          | None =>
            switch deferredHeightAnswers->Array.shift {
            | Some(answer) => Promise.resolve({Source.height: answer["height"], requestStats: []})
            | None =>
              Promise.make((resolve, reject) => {
                getHeightOrThrowResolveFns->Array.push(resolve)->ignore
                getHeightOrThrowRejectFns->Array.push(reject)->ignore
              })
            }
          }
        }),
        getItemsOrThrow: implement(#getItemsOrThrow, (
          ~fromBlock,
          ~toBlock,
          ~addressSet,
          ~knownHeight,
          ~partitionId,
          ~selection as _,
          ~itemsTarget as _,
          ~retry,
          ~logger as _,
        ) => {
          let promise = keepOnlyPendingCalls(~array=getItemsOrThrowCalls, ~fn=(~resolve, ~reject) => {
            let payload = {
              "fromBlock": fromBlock,
              "toBlock": toBlock,
              "retry": retry,
              "p": partitionId,
            }
            // Non-enumerable so it stays out of `toEqual` comparisons of the
            // payload while remaining inspectable from a test.
            payload->defineAddresses(addressSet->AddressSet.addresses)
            {
              payload,
              resolve: (
                items,
                ~latestFetchedBlockNumber=?,
                ~latestFetchedBlockHash=?,
                ~knownHeight=knownHeight,
                ~prevRangeLastBlock=?,
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
                // item came from, so those blocks carry a hash too. Without
                // them the store only ever learns the range's seam and end,
                // and reorg detection never sees the blocks events landed on.
                items->Array.forEach(item => {
                  if !(observedBlocks->Array.some(b => b.blockNumber === item.blockNumber)) {
                    observedBlocks->Array.push({
                      blockNumber: item.blockNumber,
                      blockHash: mockBlockHash(item.blockNumber),
                    })
                  }
                })
                let responseBlockStore = BlockStore.make(~ecosystem=Evm, ~shouldChecksum=false)
                observedBlocks->Array.forEach(block => {
                  let page = BlockStore.fromJs([block], ~ecosystem=Evm, ~shouldChecksum=false)
                  responseBlockStore->BlockStore.appendPage(page)
                })
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
                        block: {
                          "number": item.blockNumber,
                          "timestamp": item.blockNumber,
                          "hash": `0x${item.blockNumber->Int.toString}`,
                        }->Utils.magic,
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
                  fromBlockQueried: fromBlock,
                  latestFetchedBlockNumber,
                  stats: {
                    totalTimeElapsed: 0.,
                  },
                  requestStats: [],
                })
              },
              reject: reject->Utils.magic,
            }
          })
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
            (~onHeight) => {
              heightSubscriptionCalls->Array.push(true)->ignore
              heightSubscriptionCallbacks->Array.push(onHeight)->ignore
              heightSubscriptionUnsubscribed := false
              () => {
                heightSubscriptionUnsubscribed := true
                heightSubscriptionCallbacks->Utils.Array.clearInPlace
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

// Wait until the source has a pending getItemsOrThrow call. Queries are
// serialized by the cross-chain budget waterfall, so a chain's query only
// appears after the more-behind chains' responses release the budget.
let waitItemsQuery = async (sourceMock: t) => {
  let attempts = ref(0)
  while sourceMock.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 1000 {
    attempts := attempts.contents + 1
    await Utils.delay(0)
  }
  if sourceMock.getItemsOrThrowCalls->Array.length === 0 {
    JsError.throwWithMessage("Timed out waiting for a getItemsOrThrow call")
  }
}
