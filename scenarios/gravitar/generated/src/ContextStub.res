open Types

let insertMock = (id => id)->Jest.JestJs.fn
let updateMock = (id => id)->Jest.JestJs.fn
let context = {
  gravatar: {
    insert: gravatarInsert => {
      Js.log2("Insert:", gravatarInsert.id)
      insertMock->Jest.MockJs.fn(gravatarInsert.id)->ignore
    },
    update: gravatarUpdate => {
      Js.log2("update:", gravatarUpdate.id)
      updateMock->Jest.MockJs.fn(gravatarUpdate.id)->ignore
    },
    readEntities: [MockEntities.gravatarEntity1],
  },
}
