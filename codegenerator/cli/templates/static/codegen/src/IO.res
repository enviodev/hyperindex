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

    switch escapeTables {
    | Some(tables) if tables->Utils.Set.has(entityConfig.table) =>
      entitiesToSet->Js.Array2.forEach(item => {
        let dict = item->(Utils.magic: 'a => dict<unknown>)
        dict->Utils.Dict.forEachWithKey(
          (key, value) => {
            if value->Js.typeof === "string" {
              let value = value->(Utils.magic: unknown => string)
              // We mutate here, since we don't care
              // about the original value with \x00 anyways.
              //
              // This is unsafe, but we rely that it'll use
              // the mutated reference on retry.
              // TODO: Test it properly after we start using
              // in-memory PGLite for indexer test framework.
              dict->Js.Dict.set(
                key,
                value
                ->Js.String2.replaceByRe(%re("/\x00/g"), "")
                ->(Utils.magic: string => unknown),
              )
            }
          },
        )
      })
    | _ => ()
    }

    sql => {
      let promises = []
      if entityHistoryItemsToSet->Utils.Array.notEmpty {
        promises->Array.push(
          entityConfig.entityHistory->EntityHistory.batchInsertRows(
            ~sql,
            ~rows=entityHistoryItemsToSet,
          ),
        )
      }
      if entitiesToSet->Utils.Array.notEmpty {
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
        // There's a race condition that sql->Postgres.beginSql
        // might throw PG error, earlier, than the handled error
        // from setOrThrow will be passed through.
        // This is needed for the utf8 encoding fix.
        specificError.contents = Some(exn)
        // Improtant: Don't rethrow here, since it'll result in
        // an unhandled rejected promise error.
        // That's fine not to throw, since sql->Postgres.beginSql
        // will fail anyways.
        Promise.resolve([])
      })
      ->Promise.ignoreResolve
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
    await sql->Postgres.beginSql(sql => {
      Belt.Array.concatMany([
        //Rollback tables need to happen first in the traction
        rollbackTables,
        [setEventSyncState, setRawEvents],
        setEntities,
      ])->Belt.Array.map(dbFunc => sql->dbFunc)
    })
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
