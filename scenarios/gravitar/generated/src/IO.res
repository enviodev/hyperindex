let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  let uniqueEntities: Js.Dict.t<Types.entityRead> = Js.Dict.empty()

  //1. Get all unique entityRead values
  entityBatch->Belt.Array.forEach(entity => {
    let _ = Js.Dict.set(uniqueEntities, entity->Types.entitySerialize, entity)
  })

  let uniqueEntitiesArray = uniqueEntities->Js.Dict.values

  //2. Execute batch read
  // TODO

  //3. Set values in memory store
  let _ = entityBatch
  await Promise.resolve()
}

type batch
let createBatch = (): batch => Obj.magic()

let getContext = () => {
  // pass all references from in memory store for batch to context object and return
  ContextStub.context
}

let executeBatch = async (batch: batch) => {
  // turn in memory store into a batch query
  //execute query
  //purge batch memory store
  let _ = batch
  await Promise.resolve()
}

module InMemoryStore = {
  let gravatarDict: Js.Dict.t<Types.gravatarEntity> = Js.Dict.empty()

  let getGravatar = (~id: string) => {
    Js.Dict.get(gravatarDict, id)
  }

  let setGravatar = (~id: string, ~gravatar: Types.gravatarEntity) => {
    Js.Dict.set(gravatarDict, id, gravatar)
  }
}
