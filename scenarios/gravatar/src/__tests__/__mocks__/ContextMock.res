open Jest
open Types
let insertMock = (id => id)->JestJs.fn
let getByIdMock = (id => id)->JestJs.fn
let updateMock = (id => id)->JestJs.fn
let loadedEntitiesMock = {
  getGravatarById: id => {
    getByIdMock->MockJs.fn(id)->ignore
    None
  },
  getAllLoadedGravatar: () => [MockEntities.gravatarEntity1], //Note this should call the read function in handlers and grab all the loaded entities related to this event,
}

let mockContext: Types.context = {
  gravatar: {
    insert: gravatarInsert => {
      insertMock->MockJs.fn(gravatarInsert.id)->ignore
    },
    update: gravatarUpdate => {
      updateMock->MockJs.fn(gravatarUpdate.id)->ignore
    },
    loadedEntities: loadedEntitiesMock,
  },
}
