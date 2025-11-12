let prepareRollbackDiff = async (~persistence: Persistence.t, ~rollbackTargetCheckpointId) => {
  let inMemStore = InMemoryStore.make(~entities=Entities.allEntities, ~rollbackTargetCheckpointId)

  let deletedEntities = Js.Dict.empty()
  let setEntities = Js.Dict.empty()

  let _ =
    await Entities.allEntities
    ->Belt.Array.map(async entityConfig => {
      let entityTable = inMemStore->InMemoryStore.getInMemTable(~entityConfig)

      let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
        ~entityConfig,
        ~rollbackTargetCheckpointId,
      )

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
