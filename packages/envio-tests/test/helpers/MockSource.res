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

type mockSourceHandler = Internal.handlerArgs => promise<unit>
type mockSourceContractRegister = Internal.contractRegisterArgs => promise<unit>
type mockSourceEvent = {
  __mockHandler?: mockSourceHandler,
  __mockContractRegister?: mockSourceContractRegister,
}

// MockSource items choose their callback at response time, after ChainState has
// already been created. Install one stable registration up front and dispatch
// through callback metadata carried only by the test payload.
let makeMockSourceRegistration = (~index, ~contractName): Internal.onEventRegistration => {
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
      selectedBlockFields: Utils.Set.make(),
      selectedTransactionFields: Utils.Set.make(),
      transactionFieldMask: 0.,
      blockFieldMask: 0.,
      sighash: "",
      topicCount: 1,
      paramsMetadata: [],
    }: Internal.evmEventConfig :> Internal.eventConfig),
    isWildcard: false,
    filterByAddresses: false,
    dependsOnAddresses: true,
    addressFilterParamGroups: [],
    startBlock: None,
    handler: Some(handler),
    contractRegister: Some(contractRegister),
    resolvedWhere: {topicSelections: [], startBlock: None},
  }: Internal.evmOnEventRegistration :> Internal.onEventRegistration)
}

let defineAddresses: ({..}, array<Address.t>) => unit = %raw(`(payload, addresses) => {
  Object.defineProperty(payload, "addresses", {value: addresses});
}`)

type mockSourceRegistrationRef = ref<option<Internal.onEventRegistration>>
type mockSourceState = {onEventRegistrationRef: mockSourceRegistrationRef}

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

type getItemsOrThrowCall = {
  payload: {"fromBlock": int, "toBlock": option<int>, "retry": int, "p": string},
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
  resolveGetHeightOrThrow: int => unit,
  rejectGetHeightOrThrow: 'exn. 'exn => unit,
  getItemsOrThrowCalls: array<getItemsOrThrowCall>,
  // TODO: Remove in favor of getItemsOrThrowCalls
  resolveGetItemsOrThrow: (
    array<itemMock>,
    ~resolveAt: [#first | #all | #last]=?,
    ~latestFetchedBlockNumber: int=?,
    ~latestFetchedBlockHash: string=?,
    ~knownHeight: int=?,
    ~prevRangeLastBlock: ReorgDetection.blockData=?,
  ) => unit,
  getBlockHashesCalls: array<array<int>>,
  resolveGetBlockHashes: array<ReorgDetection.blockDataWithTimestamp> => unit,
  // Height subscription mocking
  heightSubscriptionCalls: array<bool>,
  triggerHeightSubscription: int => unit,
  unsubscribeHeightSubscription: unit => unit,
}

let make = (methods: array<method>, ~chainId=1, ~sourceFor=Source.Sync, ~pollingInterval=1000) => {
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
  let getBlockHashesCalls = []
  let getBlockHashesResolveFns = []
  // Height subscription state
  let heightSubscriptionCalls = []
  let heightSubscriptionCallbacks: array<int => unit> = []
  let heightSubscriptionUnsubscribed = ref(false)
  let state: mockSourceState = {onEventRegistrationRef: ref(None)}

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
        JsError.throwWithMessage("getHeightOrThrowResolveFns is empty")
      }
      getHeightOrThrowResolveFns->Array.forEach(resolve =>
        resolve({Source.height, requestStats: []})
      )
    },
    rejectGetHeightOrThrow: exn => {
      getHeightOrThrowRejectFns->Array.forEach(reject => reject(exn->Obj.magic))
    },
    getItemsOrThrowCalls,
    resolveGetItemsOrThrow: (
      items,
      ~resolveAt=#all,
      ~latestFetchedBlockNumber=?,
      ~latestFetchedBlockHash=?,
      ~knownHeight=?,
      ~prevRangeLastBlock=?,
    ) => {
      let calls = switch resolveAt {
      | #first => getItemsOrThrowCalls->Array.slice(~start=0, ~end=1)
      | #all => getItemsOrThrowCalls->Utils.Array.copy
      | #last => getItemsOrThrowCalls->Array.slice(~start=getItemsOrThrowCalls->Array.length - 1)
      }

      switch calls {
      | [] => JsError.throwWithMessage("getItemsOrThrowCalls is empty")
      | calls =>
        calls->Array.forEach(call =>
          call.resolve(
            items,
            ~latestFetchedBlockNumber?,
            ~latestFetchedBlockHash?,
            ~knownHeight?,
            ~prevRangeLastBlock?,
          )
        )
      }
    },
    getBlockHashesCalls,
    resolveGetBlockHashes: blockHashes => {
      if getBlockHashesResolveFns->Utils.Array.isEmpty {
        JsError.throwWithMessage("getBlockHashesResolveFns is empty")
      }
      getBlockHashesResolveFns->Array.forEach(resolve =>
        resolve({Source.result: Ok(blockHashes), requestStats: []})
      )
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
          Promise.make((resolve, reject) => {
            getHeightOrThrowResolveFns->Array.push(resolve)->ignore
            getHeightOrThrowRejectFns->Array.push(reject)->ignore
          })
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
          keepOnlyPendingCalls(~array=getItemsOrThrowCalls, ~fn=(~resolve, ~reject) => {
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

                let latestFetchedBlockHash = switch latestFetchedBlockHash {
                | Some(latestFetchedBlockHash) => latestFetchedBlockHash
                | None => `0x${latestFetchedBlockNumber->Int.toString}`
                }
                let blockHashes = [
                  (
                    {
                      blockNumber: latestFetchedBlockNumber,
                      blockHash: latestFetchedBlockHash,
                    }: ReorgDetection.blockData
                  ),
                ]
                let prevEntry = switch prevRangeLastBlock {
                | Some(prevRangeLastBlock) => Some(prevRangeLastBlock)
                | None =>
                  if fromBlock > 0 {
                    Some(
                      (
                        {
                          blockNumber: fromBlock - 1,
                          blockHash: `0x${(fromBlock - 1)->Int.toString}`,
                        }: ReorgDetection.blockData
                      ),
                    )
                  } else {
                    None
                  }
                }
                switch prevEntry {
                | Some(prev) => blockHashes->Array.unshift(prev)->ignore
                | None => ()
                }
                resolve({
                  Source.knownHeight,
                  blockHashes,
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
                  blockStore: None,
                  fromBlockQueried: fromBlock,
                  latestFetchedBlockNumber,
                  latestFetchedBlockTimestamp: latestFetchedBlockNumber,
                  stats: {
                    totalTimeElapsed: 0.,
                  },
                  requestStats: [],
                })
              },
              reject: reject->Utils.magic,
            }
          })
        }),
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
