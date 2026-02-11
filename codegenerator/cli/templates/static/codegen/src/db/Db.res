let allEntityTables: array<Table.table> = Indexer.Entities.allEntities->Belt.Array.map(entityConfig => {
  entityConfig.table
})

let schema = Schema.make(allEntityTables)
