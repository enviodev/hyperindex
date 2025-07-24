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
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~config,
  ~escapeTables=?,
) => {
  let specificError = ref(None)

  let setEventSyncState = executeSet(
    _,
    ~dbFunction=DbFunctions.EventSyncState.batchSet,
    ~items=inMemoryStore.eventSyncState->InMemoryTable.values,
  )

  let setRawEvents = executeSet(
    _,
    ~dbFunction=(sql, items) => {
      sql->PgStorage.setOrThrow(
        ~items,
        ~table=TablesStatic.RawEvents.table,
        ~itemSchema=TablesStatic.RawEvents.schema,
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
      let _ = entityHistoryItemsToSet->Js.Array2.sortInPlaceWith((a, b) => {
        EventUtils.isEarlierEvent(
          {
            timestamp: a.current.block_timestamp,
            chainId: a.current.chain_id,
            blockNumber: a.current.block_number,
            logIndex: a.current.log_index,
          },
          {
            timestamp: b.current.block_timestamp,
            chainId: b.current.chain_id,
            blockNumber: b.current.block_number,
            logIndex: b.current.log_index,
          },
        )
          ? -1
          : 1
      })
    }

    let shouldRemoveInvalidUtf8 = switch escapeTables {
    | Some(tables) if tables->Utils.Set.has(entityConfig.table) => true
    | _ => false
    }

    sql => {
      let promises = []
      if entityHistoryItemsToSet->Utils.Array.notEmpty {
        promises->Array.push(
          sql->PgStorage.setEntityHistoryOrThrow(
            ~entityHistory=entityConfig.entityHistory,
            ~rows=entityHistoryItemsToSet,
            ~shouldRemoveInvalidUtf8,
          ),
        )
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
      ->Promise.catch(exn => {
        switch exn {
        | JsError(error) /* The case is for entity history, which is not handled properly yet */
        | Persistence.StorageError({reason: JsError(error)})
        // Workaround for https://github.com/enviodev/hyperindex/issues/446
        // We do escaping only when we actually got an error writing for the first time.
        // This is not perfect, but an optimization to avoid escaping for every single item.
          if try {
            error->S.assertOrThrow(PgStorage.pgEncodingErrorSchema)
            true
          } catch {
          | _ => false
          } =>
          // Since the transaction is aborted at this point,
          // we can't simply retry the function with escaped items,
          // so propagate the error, to restart the whole batch write.
          // Also, let pass the failing table, to escape only it's items.
          // TODO: Ideally all this should be done in the file,
          // so it'll be easier to work on PG specific logic.
          specificError.contents = Some(PgStorage.PgEncodingError({table: entityConfig.table}))
        // There's a race condition that sql->Postgres.beginSql
        // might throw PG error, earlier, than the handled error
        // from setOrThrow will be passed through.
        // This is needed for the utf8 encoding fix.
        | exn => specificError.contents = Some(exn)
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
  | Some(eventIdentifier) => [
      DbFunctions.EntityHistory.deleteAllEntityHistoryAfterEventIdentifier(
        _,
        ~isUnorderedMultichainMode=config.isUnorderedMultichainMode,
        ~eventIdentifier,
      ),
      DbFunctions.EndOfBlockRangeScannedData.rollbackEndOfBlockRangeScannedDataForChain(
        _,
        ~chainId=eventIdentifier.chainId,
        ~knownBlockNumber=eventIdentifier.blockNumber,
      ),
    ]
  | None => []
  }

  try {
    let _ = await Promise.all2((
      sql->Postgres.beginSql(sql => {
        Belt.Array.concatMany([
          //Rollback tables need to happen first in the traction
          rollbackTables,
          [setEventSyncState, setRawEvents],
          setEntities,
        ])->Belt.Array.map(dbFunc => sql->dbFunc)
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
