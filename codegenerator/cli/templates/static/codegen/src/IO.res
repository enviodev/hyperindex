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

let getEntityHistoryItems = entityUpdates => {
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
      }
      entityHistoryItems->Belt.Array.concat([historyItem])
    }
    (Some(eventIdentifier), entityHistoryItems)
  })

  entityHistoryItems
}

let executeSetEntityWithHistory = (
  type entity,
  sql: Postgres.sql,
  ~inMemoryStore: InMemoryStore.t,
  ~entityMod: module(Entities.Entity with type t = entity),
): promise<unit> => {
  let rows =
    inMemoryStore.entities
    ->InMemoryStore.EntityTables.get(entityMod)
    ->InMemoryTable.Entity.rows
  let module(EntityMod) = entityMod
  let (entitiesToSet, idsToDelete, entityHistoryItemsToSet) = rows->Belt.Array.reduce(
    ([], [], []),
    ((entitiesToSet, idsToDelete, entityHistoryItemsToSet), row) => {
      switch row {
      | Updated({latest, history}) =>
        let entityHistoryItems = history->getEntityHistoryItems

        switch latest.entityUpdateAction {
        | Set(entity) => (
            entitiesToSet->Belt.Array.concat([entity]),
            idsToDelete,
            entityHistoryItemsToSet->Belt.Array.concat([entityHistoryItems]),
          )
        | Delete => (
            entitiesToSet,
            idsToDelete->Belt.Array.concat([latest.entityId]),
            entityHistoryItemsToSet->Belt.Array.concat([entityHistoryItems]),
          )
        }
      | _ => (entitiesToSet, idsToDelete, entityHistoryItemsToSet)
      }
    },
  )

  [
    EntityMod.entityHistory->EntityHistory.batchInsertRows(
      ~sql,
      ~rows=Belt.Array.concatMany(entityHistoryItemsToSet),
      ~shouldCopyCurrentEntity=!(inMemoryStore->InMemoryStore.isRollingBack),
    ),
    if entitiesToSet->Array.length > 0 {
      sql->DbFunctionsEntities.batchSet(~entityMod)(entitiesToSet)
    } else {
      Promise.resolve()
    },
    if idsToDelete->Array.length > 0 {
      sql->DbFunctionsEntities.batchDelete(~entityMod)(idsToDelete)
    } else {
      Promise.resolve()
    },
  ]
  ->Promise.all
  ->Promise.thenResolve(_ => ())
}

let executeDbFunctionsEntity = (
  type entity,
  sql: Postgres.sql,
  ~inMemoryStore: InMemoryStore.t,
  ~entityMod: module(Entities.Entity with type t = entity),
): promise<unit> => {
  let rows =
    inMemoryStore.entities
    ->InMemoryStore.EntityTables.get(entityMod)
    ->InMemoryTable.Entity.rows

  let (entitiesToSet, idsToDelete) = rows->Belt.Array.reduce(([], []), (
    (accumulatedSets, accumulatedDeletes),
    row,
  ) =>
    switch row {
    | Updated({latest: {entityUpdateAction: Set(entity)}}) => (
        Belt.Array.concat(accumulatedSets, [entity]),
        accumulatedDeletes,
      )
    | Updated({latest: {entityUpdateAction: Delete, entityId}}) => (
        accumulatedSets,
        Belt.Array.concat(accumulatedDeletes, [entityId]),
      )
    | _ => (accumulatedSets, accumulatedDeletes)
    }
  )

  let promises =
    (
      entitiesToSet->Array.length > 0
        ? [sql->DbFunctionsEntities.batchSet(~entityMod)(entitiesToSet)]
        : []
    )->Belt.Array.concat(
      idsToDelete->Array.length > 0
        ? [sql->DbFunctionsEntities.batchDelete(~entityMod)(idsToDelete)]
        : [],
    )

  promises->Promise.all->Promise.thenResolve(_ => ())
}

let executeBatch = async (sql, ~inMemoryStore: InMemoryStore.t, ~isInReorgThreshold, ~config) => {
  let entityDbExecutionComposer =
    config->Config.shouldSaveHistory(~isInReorgThreshold)
      ? executeSetEntityWithHistory
      : executeDbFunctionsEntity

  let setEventSyncState = executeSet(
    _,
    ~dbFunction=DbFunctions.EventSyncState.batchSet,
    ~items=inMemoryStore.eventSyncState->InMemoryTable.values,
  )

  let setRawEvents = executeSet(
    _,
    ~dbFunction=DbFunctions.RawEvents.batchSet,
    ~items=inMemoryStore.rawEvents->InMemoryTable.values,
  )

  let setEntities = Entities.allEntities->Belt.Array.map(entityMod => {
    entityDbExecutionComposer(_, ~entityMod, ~inMemoryStore)
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
    ]
  | None => []
  }

  let res = await sql->Postgres.beginSql(sql => {
    Belt.Array.concatMany([
      //Rollback tables need to happen first in the traction
      rollbackTables,
      [setEventSyncState, setRawEvents],
      setEntities,
    ])->Belt.Array.map(dbFunc => sql->dbFunc)
  })

  res
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

    let _ =
      await Entities.allEntities
      ->Belt.Array.map(async entityMod => {
        let module(Entity) = entityMod
        let entityMod =
          entityMod->(
            Utils.magic: module(Entities.InternalEntity) => module(Entities.Entity with
              type t = 'entity
            )
          )

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
          ~entityMod,
        )

        let entityTable = inMemStore.entities->InMemoryStore.EntityTables.get(entityMod)

        diff->Belt.Array.forEach(historyRow => {
          let eventIdentifier: Types.eventIdentifier = {
            chainId: historyRow.current.chain_id,
            blockNumber: historyRow.current.block_number,
            logIndex: historyRow.current.log_index,
            blockTimestamp: historyRow.current.block_timestamp,
          }
          switch historyRow.entityData {
          | Set(entity) =>
            entityTable->InMemoryTable.Entity.set(
              Set(entity)->Types.mkEntityUpdate(
                ~eventIdentifier,
                ~entityId=entity->Entities.getEntityId,
              ),
              ~shouldSaveHistory=false,
            )
          | Delete({id}) =>
            entityTable->InMemoryTable.Entity.set(
              Delete->Types.mkEntityUpdate(~eventIdentifier, ~entityId=id),
              ~shouldSaveHistory=false,
            )
          }
        })
      })
      ->Promise.all

    inMemStore
  }
}
