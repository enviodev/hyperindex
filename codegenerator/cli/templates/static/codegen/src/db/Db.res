let allEntityTables: array<Table.table> = Entities.allEntities->Belt.Array.map(entityConfig => {
  entityConfig.table
})

let schema = Schema.make(allEntityTables)
