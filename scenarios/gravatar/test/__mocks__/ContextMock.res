let insertMock = Sinon.stub()
let updateMock = Sinon.stub()

let mockNewGravatarContext: Types.GravatarContract.NewGravatarEvent.context = {
  gravatar: {
    insert: gravatarInsert => {
      insertMock->Sinon.callStub1(gravatarInsert.id)
    },
    update: gravatarUpdate => {
      updateMock->Sinon.callStub1(gravatarUpdate.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}

let mockUpdateGravatarContext: Types.GravatarContract.UpdatedGravatarEvent.context = {
  gravatar: {
    gravatarWithChanges: () => Some(MockEntities.gravatarEntity1),
    insert: gravatarInsert => {
      insertMock->Sinon.callStub1(gravatarInsert.id)
    },
    update: gravatarUpdate => {
      updateMock->Sinon.callStub1(gravatarUpdate.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}
