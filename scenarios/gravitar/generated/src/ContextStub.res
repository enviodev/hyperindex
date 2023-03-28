open Types

let insertMock = (id => id)->Jest.JestJs.fn
let updateMock = (id => id)->Jest.JestJs.fn

let loadedEntities = {
  getById: _id => Some(MockEntities.gravatarEntity1), //dataframe should store which event was reading this and limit access
  getAllLoaded: () => [MockEntities.gravatarEntity1], //Note this should call the read function in handlers and grab all the loaded entities related to this event,
}

let context = {
  gravatar: {
    insert: gravatarInsert => {
      /* Js.log2("Insert:", gravatarInsert.id) */
      insertMock->Jest.MockJs.fn(gravatarInsert.id)->ignore
    },
    update: gravatarUpdate => {
      /* Js.log2("update:", gravatarUpdate.id) */
      updateMock->Jest.MockJs.fn(gravatarUpdate.id)->ignore
    },
    loadedEntities,
  },
}
