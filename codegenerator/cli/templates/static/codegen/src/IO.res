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

let executeBatch = async (
  sql,
  ~batch: Batch.t,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~indexer: Indexer.t,
  ~escapeTables=?,
) => {
  let shouldSaveHistory = indexer.config->Config.shouldSaveHistory(~isInReorgThreshold)

  let specificError = ref(None)

  let setRawEvents = executeSet(
    _,
    ~dbFunction=(sql, items) => {
      sql->PgStorage.setOrThrow(
        ~items,
        ~table=InternalTable.RawEvents.table,
        ~itemSchema=InternalTable.RawEvents.schema,
        ~pgSchema=Generated.storagePgSchema,
      )
    },
    ~items=inMemoryStore.rawEvents->InMemoryTable.values,
  )

  let setEntities = Entities.allEntities->Belt.Array.map(entityConfig => {
    let entitiesToSet = []
    let idsToDelete = []

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

    let shouldRemoveInvalidUtf8 = switch escapeTables {
    | Some(tables) if tables->Utils.Set.has(entityConfig.table) => true
    | _ => false
    }

    async sql => {
      try {
        let promises = []

        if shouldSaveHistory {
          let backfillHistoryIds = Utils.Set.make()
          let batchSetUpdates = []
          // Use unnest approach
          let batchDeleteCheckpointIds = []
          let batchDeleteEntityIds = []

          rows->Js.Array2.forEach(row => {
            switch row {
            | Updated({history, containsRollbackDiffChange}) =>
              history->Js.Array2.forEach(
                (entityUpdate: EntityHistory.entityUpdate<'a>) => {
                  if !containsRollbackDiffChange {
                    // For every update we want to make sure that there's an existing history item
                    // with the current entity state. So we backfill history with checkpoint id 0,
                    // before writing updates. Don't do this if the update has a rollback diff change.
                    backfillHistoryIds->Utils.Set.add(entityUpdate.entityId)->ignore
                  }
                  switch entityUpdate.entityUpdateAction {
                  | Delete => {
                      batchDeleteEntityIds->Array.push(entityUpdate.entityId)->ignore
                      batchDeleteCheckpointIds->Array.push(entityUpdate.checkpointId)->ignore
                    }
                  | Set(_) => batchSetUpdates->Js.Array2.push(entityUpdate)->ignore
                  }
                },
              )
            | _ => ()
            }
          })

          if backfillHistoryIds->Utils.Set.size !== 0 {
            // This must run before updating entity or entity history tables
            await EntityHistory.backfillHistory(
              sql,
              ~pgSchema=Db.publicSchema,
              ~entityName=entityConfig.name,
              ~entityIndex=entityConfig.index,
              ~ids=backfillHistoryIds->Utils.Set.toArray,
            )
          }

          if batchDeleteCheckpointIds->Utils.Array.notEmpty {
            promises->Array.push(
              sql->EntityHistory.insertDeleteUpdates(
                ~pgSchema=Db.publicSchema,
                ~entityHistory=entityConfig.entityHistory,
                ~batchDeleteEntityIds,
                ~batchDeleteCheckpointIds,
              ),
            )
          }

          if batchSetUpdates->Utils.Array.notEmpty {
            if shouldRemoveInvalidUtf8 {
              let entities = batchSetUpdates->Js.Array2.map(batchSetUpdate => {
                switch batchSetUpdate.entityUpdateAction {
                | Set(entity) => entity
                | _ => Js.Exn.raiseError("Expected Set action")
                }
              })
              entities->PgStorage.removeInvalidUtf8InPlace
            }

            promises
            ->Js.Array2.push(
              sql->PgStorage.setOrThrow(
                ~items=batchSetUpdates,
                ~itemSchema=entityConfig.entityHistory.setUpdateSchema,
                ~table=entityConfig.entityHistory.table,
                ~pgSchema=Db.publicSchema,
              ),
            )
            ->ignore
          }
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
              ~pgSchema=Generated.storagePgSchema,
            ),
          )
        }
        if idsToDelete->Utils.Array.notEmpty {
          promises->Array.push(sql->DbFunctionsEntities.batchDelete(~entityConfig)(idsToDelete))
        }

        let _ = await promises->Promise.all
      } catch {
      // There's a race condition that sql->Postgres.beginSql
      // might throw PG error, earlier, than the handled error
      // from setOrThrow will be passed through.
      // This is needed for the utf8 encoding fix.
      | exn => {
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
          | S.Raised(_) => raise(normalizedExn) // But rethrow this one, since it's not a PG error
          | _ => ()
          }

          // Improtant: Don't rethrow here, since it'll result in
          // an unhandled rejected promise error.
          // That's fine not to throw, since sql->Postgres.beginSql
          // will fail anyways.
        }
      }
    }
  })

  //In the event of a rollback, rollback all meta tables based on the given
  //valid event identifier, where all rows created after this eventIdentifier should
  //be deleted
  let rollbackTables = switch inMemoryStore {
  | {rollbackTargetCheckpointId: Some(rollbackTargetCheckpointId)} =>
    Some(
      sql => {
        let promises = Entities.allEntities->Js.Array2.map(entityConfig => {
          sql->EntityHistory.rollback(
            ~pgSchema=Db.publicSchema,
            ~entityName=entityConfig.name,
            ~entityIndex=entityConfig.index,
            ~rollbackTargetCheckpointId,
          )
        })
        promises
        ->Js.Array2.push(
          sql->InternalTable.Checkpoints.rollback(
            ~pgSchema=Db.publicSchema,
            ~rollbackTargetCheckpointId,
          ),
        )
        ->ignore
        Promise.all(promises)
      },
    )
  | _ => None
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

        let setOperations = [
          sql =>
            sql->InternalTable.Chains.setProgressedChains(
              ~pgSchema=Db.publicSchema,
              ~progressedChains=batch.progressedChainsById->Utils.Dict.mapValuesToArray((
                chainAfterBatch
              ): InternalTable.Chains.progressedChain => {
                chainId: chainAfterBatch.fetchState.chainId,
                progressBlockNumber: chainAfterBatch.progressBlockNumber,
                totalEventsProcessed: chainAfterBatch.totalEventsProcessed,
              }),
            ),
          setRawEvents,
        ]->Belt.Array.concat(setEntities)

        if shouldSaveHistory {
          setOperations->Array.push(sql =>
            sql->InternalTable.Checkpoints.insert(
              ~pgSchema=Db.publicSchema,
              ~checkpointIds=batch.checkpointIds,
              ~checkpointChainIds=batch.checkpointChainIds,
              ~checkpointBlockNumbers=batch.checkpointBlockNumbers,
              ~checkpointBlockHashes=batch.checkpointBlockHashes,
              ~checkpointEventsProcessed=batch.checkpointEventsProcessed,
            )
          )
        }

        await setOperations
        ->Belt.Array.map(dbFunc => sql->dbFunc)
        ->Promise.all
      }),
      // Since effect cache currently doesn't support rollback,
      // we can run it outside of the transaction for simplicity.
      inMemoryStore.effects
      ->Js.Dict.keys
      ->Belt.Array.keepMapU(effectName => {
        let inMemTable = inMemoryStore.effects->Js.Dict.unsafeGet(effectName)
        let {idsToStore, dict, effect, invalidationsCount} = inMemTable
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
            Some(
              indexer.persistence->Persistence.setEffectCacheOrThrow(
                ~effect,
                ~items,
                ~invalidationsCount,
              ),
            )
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

let prepareRollbackDiff = async (~persistence: Persistence.t, ~rollbackTargetCheckpointId) => {
  let inMemStore = InMemoryStore.make(~entities=Entities.allEntities, ~rollbackTargetCheckpointId)

  let deletedEntities = Js.Dict.empty()
  let setEntities = Js.Dict.empty()

  let _ =
    await Entities.allEntities
    ->Belt.Array.map(async entityConfig => {
      let entityTable = inMemStore->InMemoryStore.getInMemTable(~entityConfig)

      let (removedIdsResult, restoredEntitiesResult) = await Promise.all2((
        // Get IDs of entities that should be deleted (created after rollback target with no prior history)
        persistence.sql
        ->Postgres.preparedUnsafe(
          entityConfig.entityHistory.makeGetRollbackRemovedIdsQuery(~pgSchema=Db.publicSchema),
          [rollbackTargetCheckpointId]->Utils.magic,
        )
        ->(Utils.magic: promise<unknown> => promise<array<{"id": string}>>),
        // Get entities that should be restored to their state at or before rollback target
        persistence.sql
        ->Postgres.preparedUnsafe(
          entityConfig.entityHistory.makeGetRollbackRestoredEntitiesQuery(
            ~pgSchema=Db.publicSchema,
          ),
          [rollbackTargetCheckpointId]->Utils.magic,
        )
        ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
      ))

      // Process removed IDs
      removedIdsResult->Js.Array2.forEach(data => {
        deletedEntities->Utils.Dict.push(entityConfig.name, data["id"])
        entityTable->InMemoryTable.Entity.set(
          {
            entityId: data["id"],
            checkpointId: 0,
            entityUpdateAction: Delete,
          },
          ~shouldSaveHistory=false,
          ~containsRollbackDiffChange=true,
        )
      })

      let restoredEntities = restoredEntitiesResult->S.parseOrThrow(entityConfig.rowsSchema)

      // Process restored entities
      restoredEntities->Belt.Array.forEach((entity: Entities.internalEntity) => {
        setEntities->Utils.Dict.push(entityConfig.name, entity.id)
        entityTable->InMemoryTable.Entity.set(
          {
            entityId: entity.id,
            checkpointId: 0,
            entityUpdateAction: Set(entity),
          },
          ~shouldSaveHistory=false,
          ~containsRollbackDiffChange=true,
        )
      })
    })
    ->Promise.all

  {
    "inMemStore": inMemStore,
    "deletedEntities": deletedEntities,
    "setEntities": setEntities,
  }
}
