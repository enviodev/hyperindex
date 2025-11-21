open Belt

module InMemoryStore = {
  let setEntity = (inMemoryStore, ~entityMod, entity) => {
    let inMemTable =
      inMemoryStore->InMemoryStore.getInMemTable(
        ~entityConfig=entityMod->Entities.entityModToInternal,
      )
    let entity = entity->(Utils.magic: 'a => Entities.internalEntity)
    inMemTable->InMemoryTable.Entity.set(
      Set({
        entityId: entity->Entities.getEntityId,
        checkpointId: 0.,
        entity,
      }),
      ~shouldSaveHistory=Generated.configWithoutRegistrations->Config.shouldSaveHistory(
        ~isInReorgThreshold=false,
      ),
    )
  }

  let make = (~entities=[]) => {
    let inMemoryStore = InMemoryStore.make(~entities=Entities.allEntities)
    entities->Js.Array2.forEach(((entityMod, items)) => {
      items->Js.Array2.forEach(entity => {
        inMemoryStore->setEntity(~entityMod, entity)
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
    | #setEffectCacheOrThrow
    | #loadByIdsOrThrow
    | #loadByFieldOrThrow
    | #setOrThrow
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
      if methods->Js.Array2.includes(method) {
        fn
      } else {
        (() => Js.Exn.raiseError(`storage.${(method :> string)} not implemented`))->Obj.magic
      }
    }

    let implementBody = (method: method, fn) => {
      if methods->Js.Array2.includes(method) {
        fn()
      } else {
        Js.Exn.raiseError(`storage.${(method :> string)} not implemented`)
      }
    }

    let isInitializedCalls = []
    let initializeCalls = []
    let isInitializedResolveFns = []
    let initializeResolveFns = []
    let loadByIdsOrThrowCalls = []
    let loadByFieldOrThrowCalls = []
    let dumpEffectCacheCalls = ref(0)
    let setEffectCacheOrThrowCalls = ref(0)
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
        resumeInitialStateResolveFns->Js.Array2.forEach(resolve => resolve(initialState))
      },
      resolveIsInitialized: bool => {
        isInitializedResolveFns->Js.Array2.forEach(resolve => resolve(bool))
      },
      resolveInitialize: (initialState: Persistence.initialState) => {
        initializeResolveFns->Js.Array2.forEach(resolve => resolve(initialState))
      },
      storage: {
        isInitialized: implement(#isInitialized, () => {
          isInitializedCalls->Js.Array2.push(true)->ignore
          Promise.make((resolve, _reject) => {
            isInitializedResolveFns->Js.Array2.push(resolve)->ignore
          })
        }),
        initialize: implement(#initialize, (~chainConfigs=[], ~entities=[], ~enums=[]) => {
          initializeCalls
          ->Js.Array2.push({
            "entities": entities,
            "chainConfigs": chainConfigs,
            "enums": enums,
          })
          ->ignore
          Promise.make((resolve, _reject) => {
            initializeResolveFns->Js.Array2.push(resolve)->ignore
          })
        }),
        resumeInitialState: implement(#resumeInitialState, () => {
          resumeInitialStateCalls->Js.Array2.push(true)->ignore
          Promise.make((resolve, _reject) => {
            resumeInitialStateResolveFns->Js.Array2.push(resolve)->ignore
          })
        }),
        dumpEffectCache: implement(#dumpEffectCache, () => {
          dumpEffectCacheCalls := dumpEffectCacheCalls.contents + 1
          Promise.resolve()
        }),
        setEffectCacheOrThrow: implement(#setEffectCacheOrThrow, (
          ~effect as _,
          ~items as _,
          ~initialize as _,
        ) => {
          setEffectCacheOrThrowCalls := setEffectCacheOrThrowCalls.contents + 1
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
            ->Js.Array2.push({
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
            ->Js.Array2.push({
              "fieldName": fieldName,
              "fieldValue": fieldValue->Utils.magic,
              "tableName": table.tableName,
              "operator": operator,
            })
            ->ignore
            Promise.resolve([])
          })
        },
        setOrThrow: (~items as _, ~table as _, ~itemSchema as _) => {
          implementBody(#setOrThrow, () => Js.Exn.raiseError("Not implemented"))
        },
        executeUnsafe: _ => Js.Exn.raiseError("Not implemented"),
        hasEntityHistoryRows: () => Js.Exn.raiseError("Not implemented"),
        setChainMeta: _ => Js.Exn.raiseError("Not implemented"),
        pruneStaleCheckpoints: (~safeCheckpointId as _) => Js.Exn.raiseError("Not implemented"),
        pruneStaleEntityHistory: (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) =>
          Js.Exn.raiseError("Not implemented"),
        getRollbackTargetCheckpoint: (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
          Js.Exn.raiseError("Not implemented"),
        getRollbackProgressDiff: (~rollbackTargetCheckpointId as _) =>
          Js.Exn.raiseError("Not implemented"),
        getRollbackData: (~entityConfig as _, ~rollbackTargetCheckpointId as _) =>
          Js.Exn.raiseError("Not implemented"),
        writeBatch: (
          ~batch as _,
          ~rawEvents as _,
          ~rollbackTargetCheckpointId as _,
          ~isInReorgThreshold as _,
          ~config as _,
          ~allEntities as _,
          ~updatedEffectsCache as _,
          ~updatedEntities as _,
        ) => Js.Exn.raiseError("Not implemented"),
      },
    }
  }

  let toPersistence = (storageMock: t) => {
    {
      ...Generated.codegenPersistence,
      storage: storageMock.storage,
      storageStatus: Ready({
        cleanRun: false,
        cache: Js.Dict.empty(),
        chains: [],
        reorgCheckpoints: [],
        checkpointId: 0.,
      }),
    }
  }
}

module Indexer = {
  type metric = {
    value: string,
    labels: dict<string>,
  }
  type graphqlResponse<'a> = {data?: {..} as 'a}
  type rec t = {
    getBatchWritePromise: unit => promise<unit>,
    getRollbackReadyPromise: unit => promise<unit>,
    query: 'entity. module(Entities.Entity with type t = 'entity) => promise<array<'entity>>,
    queryHistory: 'entity. module(Entities.Entity with type t = 'entity) => promise<
      array<Change.t<'entity>>,
    >,
    queryCheckpoints: unit => promise<array<InternalTable.Checkpoints.t>>,
    queryEffectCache: string => promise<array<{"id": string, "output": Js.Json.t}>>,
    metric: string => promise<array<metric>>,
    restart: unit => promise<t>,
    graphql: 'data. string => promise<graphqlResponse<'data>>,
  }

  type chainConfig = {chain: Types.chain, sources: array<Source.t>, startBlock?: int}

  let rec make = async (
    ~chains: array<chainConfig>,
    ~multichain=Config.Unordered,
    ~saveFullHistory=false,
    // Reinit storage without Hasura
    // makes tests ~1.9 seconds faster
    ~enableHasura=false,
    ~reset=true,
  ) => {
    // TODO: Should stop using global client
    PromClient.defaultRegister->PromClient.resetMetrics

    let registrations = await Generated.registerAllHandlers()

    let config = {
      let config = Generated.makeGeneratedConfig()

      let chainMap =
        chains
        ->Js.Array2.map(chainConfig => {
          let chain = ChainMap.Chain.makeUnsafe(~chainId=(chainConfig.chain :> int))
          let originalChainConfig = config.chainMap->ChainMap.get(chain)
          (
            chain,
            {
              ...originalChainConfig,
              sources: chainConfig.sources,
              startBlock: chainConfig.startBlock->Option.getWithDefault(
                originalChainConfig.startBlock,
              ),
            },
          )
        })
        ->ChainMap.fromArrayUnsafe

      {
        ...config,
        shouldRollbackOnReorg: true,
        shouldSaveFullHistory: saveFullHistory,
        enableRawEvents: false,
        chainMap,
        multichain,
      }
    }

    let sql = Db.makeClient()
    let pgSchema = Env.Db.publicSchema
    let storage = Generated.makeStorage(~sql, ~pgSchema, ~isHasuraEnabled=enableHasura)
    let persistence = {
      ...Generated.codegenPersistence,
      storageStatus: Persistence.Unknown,
      storage,
    }

    let indexer = {
      Indexer.registrations,
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
      ~persistence,
    )
    let globalState = GlobalState.make(
      ~indexer,
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
        Promise.makeAsync(async (resolve, _reject) => {
          let before = (gsManager->GlobalStateManager.getState).processedBatches
          while before >= (gsManager->GlobalStateManager.getState).processedBatches {
            await Utils.delay(1)
          }
          resolve()
        })
      },
      getRollbackReadyPromise: () => {
        Promise.makeAsync(async (resolve, _reject) => {
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
      query: (type entity, entityMod) => {
        let entityConfig = entityMod->Entities.entityModToInternal
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=entityConfig.table.tableName),
        )
        ->Promise.thenResolve(items => {
          items->S.parseOrThrow(entityConfig.rowsSchema)
        })
        ->(Utils.magic: promise<array<Internal.entity>> => promise<array<entity>>)
      },
      queryHistory: (type entity, entityMod) => {
        let entityConfig = entityMod->Entities.entityModToInternal
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(
            ~pgSchema,
            ~tableName=PgStorage.getEntityHistory(~entityConfig).table.tableName,
          ),
        )
        ->Promise.thenResolve(items => {
          items->S.parseOrThrow(
            S.array(
              S.union([
                PgStorage.getEntityHistory(~entityConfig).setChangeSchema,
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
      queryCheckpoints: () => {
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(
            ~pgSchema,
            ~tableName=InternalTable.Checkpoints.table.tableName,
          ),
        )
        ->(Utils.magic: promise<unknown> => promise<array<InternalTable.Checkpoints.t>>)
      },
      queryEffectCache: (effectName: string) => {
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=Internal.cacheTablePrefix ++ effectName),
        )
        ->(Utils.magic: promise<unknown> => promise<array<{"id": string, "output": Js.Json.t}>>)
      },
      metric: async name => {
        switch PromClient.defaultRegister->PromClient.getSingleMetric(name) {
        | Some(m) =>
          (await m.get())["values"]->Js.Array2.map(v => {
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
        make(~chains, ~enableHasura, ~multichain, ~saveFullHistory, ~reset=false)
      },
      graphql: query => {
        if !enableHasura {
          Js.Exn.raiseError(
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
  type method = [
    | #getBlockHashes
    | #getHeightOrThrow
    | #getItemsOrThrow
  ]

  type itemMock = {
    blockNumber: int,
    logIndex: int,
    handler?: Types.HandlerTypes.loader<unit, unit>,
    contractRegister?: Types.HandlerTypes.contractRegister<unit>,
  }

  type t = {
    source: Source.t,
    // Use array of bool instead of array of unit,
    // for better logging during debugging
    getHeightOrThrowCalls: array<bool>,
    resolveGetHeightOrThrow: int => unit,
    rejectGetHeightOrThrow: 'exn. 'exn => unit,
    getItemsOrThrowCalls: array<{"fromBlock": int, "toBlock": option<int>, "retry": int}>,
    resolveGetItemsOrThrow: (
      array<itemMock>,
      ~latestFetchedBlockNumber: int=?,
      ~latestFetchedBlockHash: string=?,
      ~currentBlockHeight: int=?,
      ~prevRangeLastBlock: ReorgDetection.blockData=?,
    ) => unit,
    rejectGetItemsOrThrow: 'exn. 'exn => unit,
    getBlockHashesCalls: array<array<int>>,
    resolveGetBlockHashes: array<ReorgDetection.blockDataWithTimestamp> => unit,
  }

  let make = (methods, ~chain=#1: Types.chain, ~sourceFor=Source.Sync, ~pollingInterval=1000) => {
    let implement = (method: method, fn) => {
      if methods->Js.Array2.includes(method) {
        fn
      } else {
        (() => Js.Exn.raiseError(`source.${(method :> string)} not implemented`))->Obj.magic
      }
    }

    let chain = ChainMap.Chain.makeUnsafe(~chainId=(chain :> int))
    let getHeightOrThrowCalls = []
    let getHeightOrThrowResolveFns = []
    let getHeightOrThrowRejectFns = []
    let getItemsOrThrowCalls = []
    let getItemsOrThrowResolveFns = []
    let getItemsOrThrowRejectFns = []
    let getBlockHashesCalls = []
    let getBlockHashesResolveFns = []
    {
      getHeightOrThrowCalls,
      resolveGetHeightOrThrow: height => {
        if getHeightOrThrowResolveFns->Utils.Array.isEmpty {
          Js.Exn.raiseError("getHeightOrThrowResolveFns is empty")
        }
        getHeightOrThrowResolveFns->Array.forEach(resolve => resolve(height))
      },
      rejectGetHeightOrThrow: exn => {
        getHeightOrThrowRejectFns->Array.forEach(reject => reject(exn->Obj.magic))
      },
      getItemsOrThrowCalls,
      resolveGetItemsOrThrow: (
        items,
        ~latestFetchedBlockNumber=?,
        ~latestFetchedBlockHash=?,
        ~currentBlockHeight=?,
        ~prevRangeLastBlock=?,
      ) => {
        if getItemsOrThrowResolveFns->Utils.Array.isEmpty {
          Js.Exn.raiseError("getItemsOrThrowResolveFns is empty")
        }
        getItemsOrThrowResolveFns->Array.forEach(resolve =>
          resolve({
            "items": items,
            "latestFetchedBlockNumber": latestFetchedBlockNumber,
            "latestFetchedBlockHash": latestFetchedBlockHash,
            "prevRangeLastBlock": prevRangeLastBlock,
            "currentBlockHeight": currentBlockHeight,
          })
        )
        getItemsOrThrowResolveFns->Utils.Array.clearInPlace
      },
      rejectGetItemsOrThrow: exn => {
        getItemsOrThrowRejectFns->Array.forEach(reject => reject(exn->Obj.magic))
      },
      getBlockHashesCalls,
      resolveGetBlockHashes: blockHashes => {
        if getBlockHashesResolveFns->Utils.Array.isEmpty {
          Js.Exn.raiseError("getBlockHashesResolveFns is empty")
        }
        getBlockHashesResolveFns->Array.forEach(resolve => resolve(Ok(blockHashes)))
        getBlockHashesResolveFns->Utils.Array.clearInPlace
      },
      source: {
        {
          name: "MockSource",
          sourceFor,
          poweredByHyperSync: false,
          chain,
          pollingInterval,
          getBlockHashes: implement(#getBlockHashes, (~blockNumbers, ~logger as _) => {
            getBlockHashesCalls->Js.Array2.push(blockNumbers)->ignore
            Promise.make((resolve, _reject) => {
              getBlockHashesResolveFns->Js.Array2.push(resolve)->ignore
            })
          }),
          getHeightOrThrow: implement(#getHeightOrThrow, () => {
            getHeightOrThrowCalls->Js.Array2.push(true)->ignore
            Promise.make((resolve, reject) => {
              getHeightOrThrowResolveFns->Js.Array2.push(resolve)->ignore
              getHeightOrThrowRejectFns->Js.Array2.push(reject)->ignore
            })
          }),
          getItemsOrThrow: implement(#getItemsOrThrow, (
            ~fromBlock,
            ~toBlock,
            ~addressesByContractName as _,
            ~indexingContracts as _,
            ~currentBlockHeight,
            ~partitionId as _,
            ~selection as _,
            ~retry,
            ~logger as _,
          ) => {
            getItemsOrThrowCalls
            ->Js.Array2.push({
              "fromBlock": fromBlock,
              "toBlock": toBlock,
              "retry": retry,
            })
            ->ignore
            Promise.make((resolve, reject) => {
              getItemsOrThrowResolveFns
              ->Js.Array2.push(
                data => {
                  let latestFetchedBlockNumber =
                    data["latestFetchedBlockNumber"]->Option.getWithDefault(
                      toBlock->Option.getWithDefault(fromBlock),
                    )

                  resolve({
                    Source.currentBlockHeight: data["currentBlockHeight"]->Option.getWithDefault(
                      currentBlockHeight,
                    ),
                    reorgGuard: {
                      rangeLastBlock: {
                        blockNumber: latestFetchedBlockNumber,
                        blockHash: switch data["latestFetchedBlockHash"] {
                        | Some(latestFetchedBlockHash) => latestFetchedBlockHash
                        | None => `0x${latestFetchedBlockNumber->Int.toString}`
                        },
                      },
                      prevRangeLastBlock: switch data["prevRangeLastBlock"] {
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
                    parsedQueueItems: data["items"]->Array.map(
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
                                Utils.magic: Types.HandlerTypes.loader<unit, unit> => option<
                                  Internal.handler,
                                >
                              )

                            | None => None
                            },
                            contractRegister: item.contractRegister->(
                              Utils.magic: option<
                                Types.HandlerTypes.contractRegister<unit>,
                              > => option<Internal.contractRegister>
                            ),
                            paramsRawEventSchema: S.literal(%raw(`null`))
                            ->S.shape(_ => ())
                            ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
                            getEventFiltersOrThrow: _ => Js.Exn.raiseError("Not implemented"),
                            blockSchema: S.object(_ => ())->Utils.magic,
                            transactionSchema: S.object(_ => ())->Utils.magic,
                            convertHyperSyncEventArgs: _ => Js.Exn.raiseError("Not implemented"),
                          }: Internal.evmEventConfig :> Internal.eventConfig),
                          timestamp: item.blockNumber,
                          chain,
                          blockNumber: item.blockNumber,
                          logIndex: item.logIndex,
                          event: {
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
                      totalTimeElapsed: 0,
                    },
                  })
                },
              )
              ->ignore
              getItemsOrThrowRejectFns->Js.Array2.push(reject)->ignore
            })
          }),
        }
      },
    }
  }
}

module Helper = {
  let initialEnterReorgThreshold = async (~indexerMock: Indexer.t, ~sourceMock: Source.t) => {
    open RescriptMocha

    Assert.deepEqual(
      sourceMock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="should have called getHeightOrThrow to get initial height",
    )
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    let expectedGetItemsCall1 = {"fromBlock": 0, "toBlock": Some(100), "retry": 0}

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [expectedGetItemsCall1],
      ~message="Should request items until reorg threshold",
    )
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()
  }
}

@genType
let mockRawEventRow: InternalTable.RawEvents.t = {
  chainId: 1,
  eventId: 1234567890n,
  contractName: "NftFactory",
  eventName: "SimpleNftCreated",
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: S.reverseConvertToJsonOrThrow(
    {
      Types.Transaction.transactionIndex: 20,
      hash: "0x1234567890abcdef",
    },
    Types.Transaction.schema,
  ),
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
  ~blockSchema: option<S.t<'block>>=?,
  ~transactionSchema: option<S.t<'transaction>>=?,
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
  ~onlyWhenReady=false,
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
    onlyWhenReady,
    blockSchema: blockSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
    transactionSchema: transactionSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
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
    convertHyperSyncEventArgs: _ => Js.Exn.raiseError("Not implemented"),
  }
}
