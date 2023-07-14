open Types.GravatarContract

let setMock = Sinon.stub()

let mockNewGravatarContext: NewGravatarEvent.context = {
  "gravatar": {
    NewGravatarEvent.set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}->Obj.magic

let mockUpdateGravatarContext: UpdatedGravatarEvent.context = {
  "gravatar": {
    UpdatedGravatarEvent.gravatarWithChanges: () => Some(MockEntities.gravatarEntity1),
    set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
    getOwner: Obj.magic,
  },
}->Obj.magic
