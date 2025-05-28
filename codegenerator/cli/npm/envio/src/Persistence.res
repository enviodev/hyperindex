// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

type t = {userEntities: array<Internal.entityConfig>, allEntities: array<Internal.entityConfig>}

let make = (~userEntities, ~dcRegistryEntityConfig) => {
  let allEntities = userEntities->Js.Array2.concat([dcRegistryEntityConfig])
  {userEntities, allEntities}
}
