open Types.GravatarContract

let insertMock = Sinon.stub()
let updateMock = Sinon.stub()

let mockNewGravatarContext: NewGravatarEvent.context = {
  "gravatar": {
    NewGravatarEvent.insert: gravatarInsert => {
      insertMock->Sinon.callStub1(gravatarInsert.id)
    },
    update: gravatarUpdate => {
      updateMock->Sinon.callStub1(gravatarUpdate.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}->Obj.magic

let mockUpdateGravatarContext: UpdatedGravatarEvent.context = {
  "gravatar": {
    UpdatedGravatarEvent.gravatarWithChanges: () => Some(MockEntities.gravatarEntity1),
    insert: gravatarInsert => {
      insertMock->Sinon.callStub1(gravatarInsert.id)
    },
    update: gravatarUpdate => {
      updateMock->Sinon.callStub1(gravatarUpdate.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}->Obj.magic
