open Types
let insertMock = id => id
let updateMock = id => id

let mockNewGravatarContext: Types.GravatarContract.NewGravatarEvent.context = {
  gravatar: {
    insert: gravatarInsert => {
      insertMock(gravatarInsert.id)->ignore
    },
    update: gravatarUpdate => {
      updateMock(gravatarUpdate.id)->ignore
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}

let mockUpdateGravatarContext: Types.GravatarContract.UpdatedGravatarEvent.context = {
  gravatar: {
    gravatarWithChanges: () => Some(MockEntities.gravatarEntity1),
    insert: gravatarInsert => {
      insertMock(gravatarInsert.id)->ignore
    },
    update: gravatarUpdate => {
      updateMock(gravatarUpdate.id)->ignore
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}
