type chainId = Indexer.chainId

let config = Indexer.Generated.configWithoutRegistrations

let entityConfig = (name: Indexer.Entities.name<_>): Internal.entityConfig =>
  config.userEntitiesByName
  ->Dict.get(name->(Utils.magic: Indexer.Entities.name<_> => string))
  ->Option.getOrThrow

module InMemoryStore = {
  let setEntity = (inMemoryStore, ~entityConfig: Internal.entityConfig, entity) => {
    let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)
    let entity = entity->(Utils.magic: 'a => Internal.entity)
    inMemTable->InMemoryTable.Entity.set(
      Set({
        entityId: (entity: Internal.entity).id,
        checkpointId: 0n,
        entity,
      }),
      ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold=false),
    )
  }

  let make = (~entities=[]) => {
    let inMemoryStore = InMemoryStore.make(~entities=Indexer.Generated.allEntities)
    entities->Array.forEach(((entityConfig, items)) => {
      items->Array.forEach(entity => {
        inMemoryStore->setEntity(~entityConfig, entity)
      })
    })
    inMemoryStore
  }
}

module Storage = {
  type method = [
    | #isInitialized
    | #initialize
    | #resumeInitialState
    | #dumpEffectCache
    | #loadByIdsOrThrow
    | #loadByFieldOrThrow
  ]

  type t = {
    isInitializedCalls: array<bool>,
    resolveIsInitialized: bool => unit,
    initializeCalls: array<{
      "entities": array<Internal.entityConfig>,
      "chainConfigs": array<Config.chain>,
      "enums": array<Table.enumConfig<Table.enum>>,
    }>,
    resolveInitialize: Persistence.initialState => unit,
    resumeInitialStateCalls: array<bool>,
    resolveLoadInitialState: Persistence.initialState => unit,
    loadByIdsOrThrowCalls: array<{"ids": array<string>, "tableName": string}>,
    loadByFieldOrThrowCalls: array<{
      "fieldName": string,
      "fieldValue": unknown,
      "tableName": string,
      "operator": Persistence.operator,
    }>,
    dumpEffectCacheCalls: ref<int>,
    storage: Persistence.storage,
  }

  let make = (methods: array<method>) => {
    let implement = (method: method, fn) => {
      if methods->Array.includes(method) {
        fn
      } else {
        (() => JsError.throwWithMessage(`storage.${(method :> string)} not implemented`))->Obj.magic
      }
    }

    let implementBody = (method: method, fn) => {
      if methods->Array.includes(method) {
        fn()
      } else {
        JsError.throwWithMessage(`storage.${(method :> string)} not implemented`)
      }
    }

    let isInitializedCalls = []
    let initializeCalls = []
    let isInitializedResolveFns = []
    let initializeResolveFns = []
    let loadByIdsOrThrowCalls = []
    let loadByFieldOrThrowCalls = []
    let dumpEffectCacheCalls = ref(0)
    let resumeInitialStateCalls = []
    let resumeInitialStateResolveFns = []

    {
      isInitializedCalls,
      initializeCalls,
      loadByIdsOrThrowCalls,
      loadByFieldOrThrowCalls,
      dumpEffectCacheCalls,
      resumeInitialStateCalls,
      resolveLoadInitialState: (initialState: Persistence.initialState) => {
        resumeInitialStateResolveFns->Array.forEach(resolve => resolve(initialState))
      },
      resolveIsInitialized: bool => {
        isInitializedResolveFns->Array.forEach(resolve => resolve(bool))
      },
      resolveInitialize: (initialState: Persistence.initialState) => {
        initializeResolveFns->Array.forEach(resolve => resolve(initialState))
      },
      storage: {
        isInitialized: implement(#isInitialized, () => {
          isInitializedCalls->Array.push(true)->ignore
          Promise.make((resolve, _reject) => {
            isInitializedResolveFns->Array.push(resolve)->ignore
          })
        }),
        initialize: implement(#initialize, (~chainConfigs=[], ~entities=[], ~enums=[]) => {
          initializeCalls
          ->Array.push({
            "entities": entities,
            "chainConfigs": chainConfigs,
            "enums": enums,
          })
          ->ignore
          Promise.make((resolve, _reject) => {
            initializeResolveFns->Array.push(resolve)->ignore
          })
        }),
        resumeInitialState: implement(#resumeInitialState, () => {
          resumeInitialStateCalls->Array.push(true)->ignore
          Promise.make((resolve, _reject) => {
            resumeInitialStateResolveFns->Array.push(resolve)->ignore
          })
        }),
        dumpEffectCache: implement(#dumpEffectCache, () => {
          dumpEffectCacheCalls := dumpEffectCacheCalls.contents + 1
          Promise.resolve()
        }),
        loadByIdsOrThrow: (
          type item,
          ~ids,
          ~table: Table.table,
          ~rowsSchema as _: S.t<array<item>>,
        ): promise<array<item>> => {
          implementBody(#loadByIdsOrThrow, () => {
            loadByIdsOrThrowCalls
            ->Array.push({
              "ids": ids,
              "tableName": table.tableName,
            })
            ->ignore
            Promise.resolve([])
          })
        },
        loadByFieldOrThrow: (
          ~fieldName,
          ~fieldSchema as _,
          ~fieldValue,
          ~operator,
          ~table: Table.table,
          ~rowsSchema as _,
        ) => {
          implementBody(#loadByFieldOrThrow, () => {
            loadByFieldOrThrowCalls
            ->Array.push({
              "fieldName": fieldName,
              "fieldValue": fieldValue->Utils.magic,
              "tableName": table.tableName,
              "operator": operator,
            })
            ->ignore
            Promise.resolve([])
          })
        },
        reset: () => JsError.throwWithMessage("Not implemented"),
        setChainMeta: _ => JsError.throwWithMessage("Not implemented"),
        pruneStaleCheckpoints: (~safeCheckpointId as _) =>
          JsError.throwWithMessage("Not implemented"),
        pruneStaleEntityHistory: (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) =>
          JsError.throwWithMessage("Not implemented"),
        getRollbackTargetCheckpoint: (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
          JsError.throwWithMessage("Not implemented"),
        getRollbackProgressDiff: (~rollbackTargetCheckpointId as _) =>
          JsError.throwWithMessage("Not implemented"),
        getRollbackData: (~entityConfig as _, ~rollbackTargetCheckpointId as _) =>
          JsError.throwWithMessage("Not implemented"),
        writeBatch: (
          ~batch as _,
          ~rawEvents as _,
          ~rollbackTargetCheckpointId as _,
          ~isInReorgThreshold as _,
          ~config as _,
          ~allEntities as _,
          ~updatedEffectsCache as _,
          ~updatedEntities as _,
        ) => JsError.throwWithMessage("Not implemented"),
      },
    }
  }

  let toPersistence = (storageMock: t) => {
    {
      ...PgStorage.makePersistenceFromConfig(
        ~config=Indexer.Generated.configWithoutRegistrations,
        ~storage=storageMock.storage,
      ),
      storageStatus: Ready({
        cleanRun: false,
        cache: Dict.make(),
        chains: [],
        reorgCheckpoints: [],
        checkpointId: 0n,
      }),
    }
  }
}

// Aliases to access the generated Indexer module after the local `module Indexer` shadows it
type eventLog<'a> = Internal.genericEvent<'a, Indexer.Block.t, Indexer.Transaction.t>
type handlerContext = Indexer.handlerContext
type contractRegister<'a> = Internal.genericContractRegister<
  Internal.genericContractRegisterArgs<
    Internal.genericEvent<'a, Indexer.Block.t, Indexer.Transaction.t>,
    Indexer.contractRegisterContext,
  >,
>
module Transaction = Indexer.Transaction

module Indexer = {
  type metric = {
    value: string,
    labels: dict<string>,
  }
  type graphqlResponse<'a> = {data?: {..} as 'a}
  type rec t = {
    getBatchWritePromise: unit => promise<unit>,
    getRollbackReadyPromise: unit => promise<unit>,
    query: 'entity. Indexer.Entities.name<'entity> => promise<array<'entity>>,
    queryHistory: 'entity. Indexer.Entities.name<'entity> => promise<array<Change.t<'entity>>>,
    queryRaw: 'entity. Internal.entityConfig => promise<array<'entity>>,
    queryCheckpoints: unit => promise<array<InternalTable.Checkpoints.t>>,
    queryEffectCache: string => promise<array<{"id": string, "output": JSON.t}>>,
    metric: string => promise<array<metric>>,
    restart: unit => promise<t>,
    graphql: 'data. string => promise<graphqlResponse<'data>>,
  }

  type chainConfig = {
    chain: chainId,
    sourceConfig: Config.sourceConfig,
    startBlock?: int,
    blockLag?: int,
  }

  let rec make = async (
    ~chains: array<chainConfig>,
    ~multichain=Config.Unordered,
    ~saveFullHistory=false,
    // Reinit storage without Hasura
    // makes tests ~1.9 seconds faster
    ~enableHasura=false,
    ~enableRawEvents=false,
    ~reset=true,
    ~batchSize=?,
  ) => {
    // TODO: Should stop using global client
    PromClient.defaultRegister->PromClient.resetMetrics

    // Silence logs by default in test mode unless LOG_LEVEL is explicitly set
    switch Env.userLogLevel {
    | None => Logging.setLogLevel(#silent)
    | Some(_) => ()
    }

    let registrations = await HandlerLoader.registerAllHandlers(
      ~config=Indexer.Generated.configWithoutRegistrations,
    )

    let config = {
      let config = Indexer.Generated.makeGeneratedConfig()

      let chainMap =
        chains
        ->Array.map(chainConfig => {
          let chain = ChainMap.Chain.makeUnsafe(~chainId=(chainConfig.chain :> int))
          let originalChainConfig = config.chainMap->ChainMap.get(chain)
          (
            chain,
            {
              ...originalChainConfig,
              sourceConfig: chainConfig.sourceConfig,
              startBlock: chainConfig.startBlock->Option.getOr(originalChainConfig.startBlock),
              blockLag: chainConfig.blockLag->Option.getOr(originalChainConfig.blockLag),
            },
          )
        })
        ->ChainMap.fromArrayUnsafe

      {
        ...config,
        shouldRollbackOnReorg: true,
        shouldSaveFullHistory: saveFullHistory,
        enableRawEvents,
        chainMap,
        multichain,
        batchSize: batchSize->Option.getOr(config.batchSize),
      }
    }

    let sql = PgStorage.makeClient()
    let pgSchema = Env.Db.publicSchema
    let storage = PgStorage.makeStorageFromEnv(
      ~config,
      ~sql,
      ~pgSchema,
      ~isHasuraEnabled=enableHasura,
    )
    let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)

    let ctx = {
      Ctx.registrations,
      config,
      persistence,
    }

    let graphqlClient = Rest.client(`${Env.Hasura.url}/v1/graphql`)
    let graphqlRoute = Rest.route(() => {
      method: Post,
      path: "",
      input: s => s.field("query", S.string),
      responses: [s => s.data(S.unknown)],
    })

    let gsManagerRef = ref(None)

    await persistence->Persistence.init(~chainConfigs=config.chainMap->ChainMap.values, ~reset)

    let chainManager = await ChainManager.makeFromDbState(
      ~initialState=persistence->Persistence.getInitializedState,
      ~config,
      ~registrations,
    )
    let globalState = GlobalState.make(
      ~ctx,
      ~chainManager,
      ~isDevelopmentMode=false,
      ~shouldUseTui=false,
    )
    let gsManager = globalState->GlobalStateManager.make
    gsManagerRef := Some(gsManager)
    gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChains))
    /*
        NOTE:
          This `ProcessEventBatch` dispatch shouldn't be necessary but we are adding for safety, it should immediately return doing 
          nothing since there is no events on the queues.
 */
    gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch)

    {
      getBatchWritePromise: () => {
        Utils.Promise.makeAsync(async (resolve, _reject) => {
          let before = (gsManager->GlobalStateManager.getState).processedBatches
          while before >= (gsManager->GlobalStateManager.getState).processedBatches {
            await Utils.delay(1)
          }
          resolve()
        })
      },
      getRollbackReadyPromise: () => {
        Utils.Promise.makeAsync(async (resolve, _reject) => {
          while (
            switch (gsManager->GlobalStateManager.getState).rollbackState {
            | RollbackReady(_) => false
            | _ => true
            }
          ) {
            await Utils.delay(1)
          }
          // Skip an extra microtask for indexer to fire actions
          await Utils.delay(0)
          resolve()
        })
      },
      query: (type entity, name: Indexer.Entities.name<entity>) => {
        let ec = entityConfig(name)
        sql
        ->Postgres.unsafe(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=ec.table.tableName))
        ->Promise.thenResolve(items => {
          items->S.parseOrThrow(ec.rowsSchema)
        })
        ->(Utils.magic: promise<array<Internal.entity>> => promise<array<entity>>)
      },
      queryHistory: (type entity, name: Indexer.Entities.name<entity>) => {
        let ec = entityConfig(name)
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(
            ~pgSchema,
            ~tableName=PgStorage.getEntityHistory(~entityConfig=ec).table.tableName,
          ),
        )
        ->Promise.thenResolve(items => {
          items->S.parseOrThrow(
            S.array(
              S.union([
                PgStorage.getEntityHistory(~entityConfig=ec).setChangeSchema,
                S.object((s): Change.t<'entity> => {
                  s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
                  Delete({
                    entityId: s.field("id", S.string),
                    checkpointId: s.field(
                      EntityHistory.checkpointIdFieldName,
                      EntityHistory.unsafeCheckpointIdSchema,
                    ),
                  })
                }),
              ]),
            ),
          )
        })
        ->(
          Utils.magic: promise<array<Change.t<Internal.entity>>> => promise<array<Change.t<entity>>>
        )
      },
      queryRaw: (type entity, entityConfig: Internal.entityConfig) => {
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=entityConfig.table.tableName),
        )
        ->Promise.thenResolve(items => {
          items->S.parseOrThrow(entityConfig.rowsSchema)
        })
        ->(Utils.magic: promise<array<Internal.entity>> => promise<array<entity>>)
      },
      queryCheckpoints: () => {
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(
            ~pgSchema,
            ~tableName=InternalTable.Checkpoints.table.tableName,
          ),
        )
        ->Promise.thenResolve(rows =>
          rows
          ->(Utils.magic: unknown => array<unknown>)
          ->Array.map(row => row->S.convertOrThrow(InternalTable.Checkpoints.dbSchema))
        )
      },
      queryEffectCache: (effectName: string) => {
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=Internal.cacheTablePrefix ++ effectName),
        )
        ->(Utils.magic: promise<unknown> => promise<array<{"id": string, "output": JSON.t}>>)
      },
      metric: async name => {
        switch PromClient.defaultRegister->PromClient.getSingleMetric(name) {
        | Some(m) =>
          (await m.get())["values"]->Array.map(v => {
            value: v.value->Belt.Int.toString,
            labels: v.labels,
          })
        | None => []
        }
      },
      restart: () => {
        let state = gsManager->GlobalStateManager.getState
        gsManager->GlobalStateManager.setState({
          ...gsManager->GlobalStateManager.getState,
          id: state.id + 1,
        })
        make(
          ~chains,
          ~enableHasura,
          ~enableRawEvents,
          ~multichain,
          ~saveFullHistory,
          ~reset=false,
          ~batchSize?,
        )
      },
      graphql: query => {
        if !enableHasura {
          JsError.throwWithMessage(
            "It's require to set ~enableHasura=true during indexer mock creation to access this feature.",
          )
        }

        graphqlRoute
        ->Rest.fetch(query, ~client=graphqlClient)
        ->(Utils.magic: promise<unknown> => promise<graphqlResponse<{..}>>)
      },
    }
  }
}

module Source = {
  module CallPayload = {
    @get external addresses: {..} => dict<array<Address.t>> = "addresses"
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
    handler?: Internal.genericHandlerArgs<eventLog<unknown>, handlerContext> => promise<unit>,
    contractRegister?: contractRegister<unit>,
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

  let make = (methods, ~chain=#1: chainId, ~sourceFor=Source.Sync, ~pollingInterval=1000) => {
    let implement = (method: method, fn) => {
      if methods->Array.includes(method) {
        fn
      } else {
        (() => JsError.throwWithMessage(`source.${(method :> string)} not implemented`))->Obj.magic
      }
    }

    let chain = ChainMap.Chain.makeUnsafe(~chainId=(chain :> int))
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
        getHeightOrThrowResolveFns->Array.forEach(resolve => resolve(height))
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
        getBlockHashesResolveFns->Array.forEach(resolve => resolve(Ok(blockHashes)))
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
        {
          name: "MockSource",
          sourceFor,
          poweredByHyperSync: false,
          chain,
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
            ~addressesByContractName as _addressesByContractName,
            ~indexingAddresses as _,
            ~knownHeight,
            ~partitionId,
            ~selection as _,
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
              let _ = %raw(`Object.defineProperty(payload, 'addresses', { value: _addressesByContractName })`)
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

                  resolve({
                    Source.knownHeight,
                    reorgGuard: {
                      rangeLastBlock: {
                        blockNumber: latestFetchedBlockNumber,
                        blockHash: switch latestFetchedBlockHash {
                        | Some(latestFetchedBlockHash) => latestFetchedBlockHash
                        | None => `0x${latestFetchedBlockNumber->Int.toString}`
                        },
                      },
                      prevRangeLastBlock: switch prevRangeLastBlock {
                      | Some(prevRangeLastBlock) => Some(prevRangeLastBlock)
                      | None =>
                        if fromBlock > 0 {
                          Some({
                            blockNumber: fromBlock - 1,
                            blockHash: `0x${(fromBlock - 1)->Int.toString}`,
                          })
                        } else {
                          None
                        }
                      },
                    },
                    parsedQueueItems: items->Array.map(
                      item => {
                        Internal.Event({
                          eventConfig: ({
                            id: "MockEvent",
                            contractName: "MockContract",
                            name: "MockEvent",
                            isWildcard: false,
                            filterByAddresses: false,
                            dependsOnAddresses: false,
                            handler: switch item.handler {
                            | Some(handler) =>
                              (
                                ({context} as args) => {
                                  // We don't want preload optimization for the tests
                                  if context.isPreload {
                                    Promise.resolve()
                                  } else {
                                    handler(args)
                                  }
                                }
                              )->(
                                Utils.magic: (
                                  Internal.genericHandlerArgs<
                                    eventLog<unknown>,
                                    handlerContext,
                                  > => promise<unit>
                                ) => option<Internal.handler>
                              )

                            | None => None
                            },
                            contractRegister: item.contractRegister->(
                              Utils.magic: option<contractRegister<unit>> => option<
                                Internal.contractRegister,
                              >
                            ),
                            paramsRawEventSchema: S.literal(%raw(`null`))
                            ->S.shape(_ => ())
                            ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
                            simulateParamsSchema: S.unknown
                            ->S.shape(_ => ())
                            ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
                            getEventFiltersOrThrow: _ =>
                              JsError.throwWithMessage("Not implemented"),
                            convertHyperSyncEventArgs: _ =>
                              JsError.throwWithMessage("Not implemented"),
                            selectedBlockFields: Utils.Set.make(),
                            selectedTransactionFields: Utils.Set.make(),
                          }: Internal.evmEventConfig :> Internal.eventConfig),
                          timestamp: item.blockNumber,
                          chain,
                          blockNumber: item.blockNumber,
                          logIndex: item.logIndex,
                          event: {
                            contractName: "MockContract",
                            eventName: "MockEvent",
                            params: %raw(`{}`),
                            chainId: chain->ChainMap.Chain.toChainId,
                            srcAddress: "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
                            logIndex: item.logIndex,
                            transaction: %raw(`null`),
                            block: {
                              "number": item.blockNumber,
                              "timestamp": item.blockNumber,
                              "hash": `0x${item.blockNumber->Int.toString}`,
                            }->Utils.magic,
                          },
                        })
                      },
                    ),
                    fromBlockQueried: fromBlock,
                    latestFetchedBlockNumber,
                    latestFetchedBlockTimestamp: latestFetchedBlockNumber,
                    stats: {
                      totalTimeElapsed: 0.,
                    },
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
      },
    }
  }
}

module Helper = {
  let initialEnterReorgThreshold = async (
    ~t: Vitest.testContext,
    ~indexerMock: Indexer.t,
    ~sourceMock: Source.t,
  ) => {
    t.expect(
      sourceMock.getHeightOrThrowCalls->Array.length,
      ~message="should have called getHeightOrThrow to get initial height",
    ).toEqual(1)
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload),
      ~message="Should request items until reorg threshold",
    ).toEqual(// fromBlock 1 since it's in the config.yaml start_block is 1
    [{"fromBlock": 1, "toBlock": Some(100), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()
  }
}

let mockRawEventRow: InternalTable.RawEvents.t = {
  chainId: 1,
  eventId: 1234567890n,
  contractName: "NftFactory",
  eventName: "SimpleNftCreated",
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: %raw(`{"transactionIndex": 20, "hash": "0x1234567890abcdef"}`),
  srcAddress: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  blockHash: "0x9876543210fedcba9876543210fedcba987654321",
  blockTimestamp: 1620720000,
  blockFields: %raw(`{}`),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}

let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let evmEventConfig = (
  ~id=eventId,
  ~contractName="ERC20",
  ~blockFieldNames: array<Internal.evmBlockField>=[],
  ~transactionFieldNames: array<Internal.evmTransactionField>=[],
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
): Internal.evmEventConfig => {
  {
    id,
    contractName,
    name: "EventWithoutFields",
    isWildcard,
    filterByAddresses,
    dependsOnAddresses: filterByAddresses ||
    dependsOnAddresses->Belt.Option.getWithDefault(!isWildcard),
    handler: None,
    contractRegister: None,
    paramsRawEventSchema: S.literal(%raw(`null`))
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
    simulateParamsSchema: S.unknown
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
    getEventFiltersOrThrow: _ =>
      switch dependsOnAddresses {
      | Some(true) =>
        Dynamic(
          addresses => [
            {
              topic0: [
                // This is a sighash in the original code
                id->EvmTypes.Hex.fromStringUnsafe,
              ],
              topic1: addresses->Utils.magic,
              topic2: [],
              topic3: [],
            },
          ],
        )
      | _ =>
        Static([
          {
            topic0: [
              // This is a sighash in the original code
              id->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: [],
            topic2: [],
            topic3: [],
          },
        ])
      },
    convertHyperSyncEventArgs: _ => JsError.throwWithMessage("Not implemented"),
    selectedBlockFields: Utils.Set.fromArray(blockFieldNames),
    selectedTransactionFields: Utils.Set.fromArray(transactionFieldNames),
  }
}
