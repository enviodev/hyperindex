open Belt

let executeSet = (
  sql: Postgres.sql,
  ~items: array<'a>,
  ~dbFunction: (Postgres.sql, array<'a>) => promise<unit>,
) => {
  if items->Array.length > 0 {
    sql->dbFunction(items)
  } else {
    Promise.resolve()
  }
}

let getEntityHistoryItems = (entityUpdates, ~containsRollbackDiffChange) => {
  let (_, entityHistoryItems) = entityUpdates->Belt.Array.reduce((None, []), (
    prev: (option<Types.eventIdentifier>, array<EntityHistory.historyRow<_>>),
    entityUpdate: Types.entityUpdate<'a>,
  ) => {
    let (optPreviousEventIdentifier, entityHistoryItems) = prev

    let {eventIdentifier, entityUpdateAction, entityId} = entityUpdate
    let entityHistoryItems = {
      let historyItem: EntityHistory.historyRow<_> = {
        current: {
          chain_id: eventIdentifier.chainId,
          block_timestamp: eventIdentifier.blockTimestamp,
          block_number: eventIdentifier.blockNumber,
          log_index: eventIdentifier.logIndex,
        },
        previous: optPreviousEventIdentifier->Belt.Option.map(prev => {
          EntityHistory.chain_id: prev.chainId,
          block_timestamp: prev.blockTimestamp,
          block_number: prev.blockNumber,
          log_index: prev.logIndex,
        }),
        entityData: switch entityUpdateAction {
        | Set(entity) => Set(entity)
        | Delete => Delete({id: entityId})
        },
        containsRollbackDiffChange,
      }
      entityHistoryItems->Belt.Array.concat([historyItem])
    }
    (Some(eventIdentifier), entityHistoryItems)
  })

  entityHistoryItems
}

let executeBatch = async (
  sql,
  ~progressedChains: array<Batch.progressedChain>,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~config,
  ~escapeTables=?,
) => {
  let specificError = ref(None)

  let setRawEvents = executeSet(
    _,
    ~dbFunction=(sql, items) => {
      sql->PgStorage.setOrThrow(
        ~items,
        ~table=InternalTable.RawEvents.table,
        ~itemSchema=InternalTable.RawEvents.schema,
        ~pgSchema=Config.storagePgSchema,
      )
    },
    ~items=inMemoryStore.rawEvents->InMemoryTable.values,
  )

  let setEntities = Entities.allEntities->Belt.Array.map(entityConfig => {
    let entitiesToSet = []
    let idsToDelete = []
    let entityHistoryItemsToSet = []

    let rows =
      inMemoryStore
      ->InMemoryStore.getInMemTable(~entityConfig)
      ->InMemoryTable.Entity.rows

    rows->Js.Array2.forEach(row => {
      switch row {
      | Updated({latest: {entityUpdateAction: Set(entity)}}) => entitiesToSet->Array.push(entity)
      | Updated({latest: {entityUpdateAction: Delete, entityId}}) =>
        idsToDelete->Array.push(entityId)
      | _ => ()
      }
    })

    if config->Config.shouldSaveHistory(~isInReorgThreshold) {
      rows->Js.Array2.forEach(row => {
        switch row {
        | Updated({history, containsRollbackDiffChange}) =>
          let entityHistoryItems = history->getEntityHistoryItems(~containsRollbackDiffChange)
          entityHistoryItemsToSet->Js.Array2.pushMany(entityHistoryItems)->ignore
        | _ => ()
        }
      })

      // Keep history items in the order of the events. Without sorting,
      // they will only be in order per row, but not across the whole entity
      // table.

      switch config.multichain {
      | Ordered =>
        let _ = entityHistoryItemsToSet->Js.Array2.sortInPlaceWith((a, b) => {
          EventUtils.isEarlier(
            (
              a.current.block_timestamp,
              a.current.chain_id,
              a.current.block_number,
              a.current.log_index,
            ),
            (
              b.current.block_timestamp,
              b.current.chain_id,
              b.current.block_number,
              b.current.log_index,
            ),
          )
            ? -1
            : 1
        })
      | Unordered =>
        let _ = entityHistoryItemsToSet->Js.Array2.sortInPlaceWith((a, b) => {
          EventUtils.isEarlierUnordered(
            (a.current.chain_id, a.current.block_number, a.current.log_index),
            (b.current.chain_id, b.current.block_number, b.current.log_index),
          )
            ? -1
            : 1
        })
      }
    }

    let shouldRemoveInvalidUtf8 = switch escapeTables {
    | Some(tables) if tables->Utils.Set.has(entityConfig.table) => true
    | _ => false
    }

    sql => {
      let promises = []
      if entityHistoryItemsToSet->Utils.Array.notEmpty {
        promises
        ->Js.Array2.pushMany(
          sql->PgStorage.setEntityHistoryOrThrow(
            ~entityHistory=entityConfig.entityHistory,
            ~rows=entityHistoryItemsToSet,
            ~shouldRemoveInvalidUtf8,
          ),
        )
        ->ignore
      }
      if entitiesToSet->Utils.Array.notEmpty {
        if shouldRemoveInvalidUtf8 {
          entitiesToSet->PgStorage.removeInvalidUtf8InPlace
        }
        promises->Array.push(
          sql->PgStorage.setOrThrow(
            ~items=entitiesToSet,
            ~table=entityConfig.table,
            ~itemSchema=entityConfig.schema,
            ~pgSchema=Config.storagePgSchema,
          ),
        )
      }
      if idsToDelete->Utils.Array.notEmpty {
        promises->Array.push(sql->DbFunctionsEntities.batchDelete(~entityConfig)(idsToDelete))
      }
      // This should have await, to properly propagate errors to the caller.
      promises
      ->Promise.all
      // There's a race condition that sql->Postgres.beginSql
      // might throw PG error, earlier, than the handled error
      // from setOrThrow will be passed through.
      // This is needed for the utf8 encoding fix.
      ->Promise.catch(exn => {
        /* Note: Entity History doesn't return StorageError yet, and directly throws JsError */
        let normalizedExn = switch exn {
        | JsError(_) => exn
        | Persistence.StorageError({reason: exn}) => exn
        | _ => exn
        }->Js.Exn.anyToExnInternal

        switch normalizedExn {
        | JsError(error) =>
          // Workaround for https://github.com/enviodev/hyperindex/issues/446
          // We do escaping only when we actually got an error writing for the first time.
          // This is not perfect, but an optimization to avoid escaping for every single item.

          switch error->S.parseOrThrow(PgStorage.pgErrorMessageSchema) {
          | `current transaction is aborted, commands ignored until end of transaction block` => ()
          | `invalid byte sequence for encoding "UTF8": 0x00` =>
            // Since the transaction is aborted at this point,
            // we can't simply retry the function with escaped items,
            // so propagate the error, to restart the whole batch write.
            // Also, pass the failing table, to escape only its items.
            // TODO: Ideally all this should be done in the file,
            // so it'll be easier to work on PG specific logic.
            specificError.contents = Some(PgStorage.PgEncodingError({table: entityConfig.table}))
          | _ => specificError.contents = Some(exn->Utils.prettifyExn)
          | exception _ => ()
          }
        | _ => ()
        }

        // Improtant: Don't rethrow here, since it'll result in
        // an unhandled rejected promise error.
        // That's fine not to throw, since sql->Postgres.beginSql
        // will fail anyways.
        Promise.resolve([])
      })
      ->(Utils.magic: promise<array<unit>> => promise<unit>)
    }
  })

  //In the event of a rollback, rollback all meta tables based on the given
  //valid event identifier, where all rows created after this eventIdentifier should
  //be deleted
  let rollbackTables = switch inMemoryStore.rollBackEventIdentifier {
  | Some(eventIdentifier) =>
    Some(
      sql =>
        Promise.all2((
          sql->DbFunctions.EntityHistory.deleteAllEntityHistoryAfterEventIdentifier(
            ~isUnorderedMultichainMode=switch config.multichain {
            | Unordered => true
            | Ordered => false
            },
            ~eventIdentifier,
          ),
          sql->DbFunctions.EndOfBlockRangeScannedData.rollbackEndOfBlockRangeScannedDataForChain(
            ~chainId=eventIdentifier.chainId,
            ~knownBlockNumber=eventIdentifier.blockNumber,
          ),
        )),
    )
  | None => None
  }

  try {
    let _ = await Promise.all2((
      sql->Postgres.beginSql(async sql => {
        //Rollback tables need to happen first in the traction
        switch rollbackTables {
        | Some(rollbackTables) =>
          let _ = await rollbackTables(sql)
        | None => ()
        }

        await Belt.Array.concatMany([
          [
            sql =>
              sql->InternalTable.Chains.setProgressedChains(
                ~pgSchema=Db.publicSchema,
                ~progressedChains,
              ),
            setRawEvents,
          ],
          setEntities,
        ])
        ->Belt.Array.map(dbFunc => sql->dbFunc)
        ->Promise.all
      }),
      // Since effect cache currently doesn't support rollback,
      // we can run it outside of the transaction for simplicity.
      inMemoryStore.effects
      ->Js.Dict.keys
      ->Belt.Array.keepMapU(effectName => {
        let inMemTable = inMemoryStore.effects->Js.Dict.unsafeGet(effectName)
        let {idsToStore, dict, effect} = inMemTable
        switch idsToStore {
        | [] => None
        | ids => {
            let items = Belt.Array.makeUninitializedUnsafe(ids->Belt.Array.length)
            ids->Belt.Array.forEachWithIndex((index, id) => {
              items->Js.Array2.unsafe_set(
                index,
                (
                  {
                    id,
                    output: dict->Js.Dict.unsafeGet(id),
                  }: Internal.effectCacheItem
                ),
              )
            })
            Some(config.persistence->Persistence.setEffectCacheOrThrow(~effect, ~items))
          }
        }
      })
      ->Promise.all,
    ))

    // Just in case, if there's a not PG-specific error.
    switch specificError.contents {
    | Some(specificError) => raise(specificError)
    | None => ()
    }
  } catch {
  | exn =>
    raise(
      switch specificError.contents {
      | Some(specificError) => specificError
      | None => exn
      },
    )
  }
}

module RollBack = {
  exception DecodeError(S.error)
  let rollBack = async (
    ~chainId,
    ~blockTimestamp,
    ~blockNumber,
    ~logIndex,
    ~isUnorderedMultichainMode,
  ) => {
    let rollBackEventIdentifier: Types.eventIdentifier = {
      chainId,
      blockTimestamp,
      blockNumber,
      logIndex,
    }

    let inMemStore = InMemoryStore.make(~rollBackEventIdentifier)

    let deletedEntities = Js.Dict.empty()
    let setEntities = Js.Dict.empty()

    let fullDiff: dict<array<EntityHistory.historyRow<Entities.internalEntity>>> = Js.Dict.empty()

    let _ =
      await Entities.allEntities
      ->Belt.Array.map(async entityConfig => {
        let diff = await Db.sql->DbFunctions.EntityHistory.getRollbackDiff(
          isUnorderedMultichainMode
            ? UnorderedMultichain({
                reorgChainId: chainId,
                safeBlockNumber: blockNumber,
              })
            : OrderedMultichain({
                safeBlockTimestamp: blockTimestamp,
                reorgChainId: chainId,
                safeBlockNumber: blockNumber,
              }),
          ~entityConfig,
        )
        if diff->Utils.Array.notEmpty {
          fullDiff->Js.Dict.set(entityConfig.name, diff)
        }

        let entityTable = inMemStore->InMemoryStore.getInMemTable(~entityConfig)

        diff->Belt.Array.forEach(historyRow => {
          let eventIdentifier: Types.eventIdentifier = {
            chainId: historyRow.current.chain_id,
            blockNumber: historyRow.current.block_number,
            logIndex: historyRow.current.log_index,
            blockTimestamp: historyRow.current.block_timestamp,
          }
          switch historyRow.entityData {
          | Set(entity: Entities.internalEntity) =>
            setEntities->Utils.Dict.push(entityConfig.name, entity.id)
            entityTable->InMemoryTable.Entity.set(
              Set(entity)->Types.mkEntityUpdate(~eventIdentifier, ~entityId=entity.id),
              ~shouldSaveHistory=false,
              ~containsRollbackDiffChange=true,
            )
          | Delete({id}) =>
            deletedEntities->Utils.Dict.push(entityConfig.name, id)
            entityTable->InMemoryTable.Entity.set(
              Delete->Types.mkEntityUpdate(~eventIdentifier, ~entityId=id),
              ~shouldSaveHistory=false,
              ~containsRollbackDiffChange=true,
            )
          }
        })
      })
      ->Promise.all

    {
      "inMemStore": inMemStore,
      "deletedEntities": deletedEntities,
      "setEntities": setEntities,
      "fullDiff": fullDiff,
    }
  }
}
