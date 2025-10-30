type chainRange = {startBlock: int, endBlock: int}

type state = Unititialized | Running | Finished

type t = {
  run: dict<chainRange> => promise<unit>,
  history: unit => promise<dict<array<unknown>>>,
}

let factory = (
  ~registerAllHandlers,
  ~makeGeneratedConfig,
  ~makePgClient,
  ~makeStorage,
  ~codegenPersistence,
  ~createGlobalStateAndRun,
) => {
  () => {
    let state = ref(Unititialized)

    let registrations: EventRegister.registrations = registerAllHandlers()
    let config: Config.t = {
      let config = makeGeneratedConfig()

      {
        ...config,
        shouldRollbackOnReorg: true,
        shouldSaveFullHistory: true,
      }
    }

    let sql = makePgClient()
    let pgSchema = "envio_internal_test_indexer"
    let storage = makeStorage(~sql, ~pgSchema, ~isHasuraEnabled=false)
    let persistence: Persistence.t = {
      ...codegenPersistence,
      storageStatus: Persistence.Unknown,
      storage,
      sql,
    }

    let run = async chainsToRun => {
      switch state.contents {
      | Unititialized =>
        state.contents = Running

        let runningChains = []

        let chainsToRunKeys = chainsToRun->Js.Dict.keys
        if chainsToRunKeys->Utils.Array.isEmpty {
          Js.Exn.raiseError("No chains to run")
        }
        chainsToRunKeys->Js.Array2.forEach(key => {
          switch key->Belt.Int.fromString {
          | None => Js.Exn.raiseError("Invalid chain key")
          | Some(chainId) =>
            // It'll throw with invalid chain Id
            let _ = config->Config.getChain(~chainId)
            runningChains
            ->Js.Array2.push(ChainMap.Chain.makeUnsafe(~chainId))
            ->ignore
          }
        })

        let chainMap = config.chainMap->ChainMap.mapWithKey((chain, chainConfig) => {
          let chainToRun = chainsToRun->Utils.Dict.dangerouslyGetByIntNonOption(chainConfig.id)

          switch chainToRun {
          | Some(chainToRun) => {
              if chainConfig.startBlock > chainToRun.startBlock {
                Js.Exn.raiseError("Start block is greater than the start block of the chain")
              }
              switch chainConfig.endBlock {
              | Some(endBlock) =>
                if endBlock < chainToRun.endBlock {
                  Js.Exn.raiseError("End block is less than the end block of the chain")
                }
              | None => ()
              }

              {
                ...chainConfig,
                startBlock: chainToRun.startBlock,
                endBlock: chainToRun.endBlock,
                sources: chainConfig.sources,
                maxReorgDepth: 0, // We want always be in reorg threshold
              }
            }
          | None => {
              ...chainConfig,
              sources: [
                {
                  name: "MockSource",
                  sourceFor: Sync,
                  poweredByHyperSync: false,
                  chain,
                  pollingInterval: 1_000_000_000,
                  getBlockHashes: (~blockNumbers as _, ~logger as _) => {
                    Js.Exn.raiseError("Not implemented")
                  },
                  getHeightOrThrow: () => Promise.make((_, _) => ()),
                  getItemsOrThrow: (
                    ~fromBlock as _,
                    ~toBlock as _,
                    ~addressesByContractName as _,
                    ~indexingContracts as _,
                    ~currentBlockHeight as _,
                    ~partitionId as _,
                    ~selection as _,
                    ~retry as _,
                    ~logger as _,
                  ) => {
                    Js.Exn.raiseError("Not implemented")
                  },
                },
              ],
            }
          }
        })

        let config = {
          ...config,
          chainMap,
        }

        await persistence->Persistence.init(
          ~chainConfigs=config.chainMap->ChainMap.values,
          ~reset=true,
        )

        let indexer = {
          Indexer.registrations,
          config,
          persistence,
        }

        await createGlobalStateAndRun(~indexer, ~runningChains)

        state.contents = Finished
      | Running => Js.Exn.raiseError("Test indexer is already running")
      | Finished => Js.Exn.raiseError("Test indexer has already finished")
      }
    }
    let history = async () => {
      switch state.contents {
      | Unititialized
      | Running =>
        Js.Dict.empty()
      | Finished =>
        let data = Js.Dict.fromArray([
          (
            "checkpoints",
            await sql
            ->Postgres.unsafe(
              PgStorage.makeLoadAllQuery(
                ~pgSchema,
                ~tableName=InternalTable.Checkpoints.table.tableName,
              ),
            )
            ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
          ),
        ])
        let _ = await Promise.all(
          persistence.allEntities->Js.Array2.map(entityConfig => {
            sql
            ->Postgres.unsafe(
              PgStorage.makeLoadAllQuery(
                ~pgSchema,
                ~tableName=entityConfig.entityHistory.table.tableName,
              ),
            )
            ->Promise.thenResolve(items => {
              data->Js.Dict.set(
                entityConfig.name,
                items
                ->S.parseOrThrow(
                  S.array(
                    S.union([
                      entityConfig.entityHistory.setUpdateSchema,
                      S.object(
                        (s): EntityHistory.entityUpdate<'entity> => {
                          s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
                          {
                            entityId: s.field("id", S.string),
                            checkpointId: s.field(EntityHistory.checkpointIdFieldName, S.int),
                            entityUpdateAction: Delete,
                          }
                        },
                      ),
                    ]),
                  ),
                )
                ->(
                  Utils.magic: array<EntityHistory.entityUpdate<Internal.entity>> => array<unknown>
                ),
              )
            })
          }),
        )
        data
      }
    }
    {
      run,
      history,
    }
  }
}
