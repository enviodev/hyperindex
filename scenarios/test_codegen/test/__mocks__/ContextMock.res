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
  "log": {
    "debug": Js.log,
    "info": Js.log,
    "warn": Js.log,
    "error": Js.log,
    "errorWithExn": Js.log2,
  },
  "gravatar": {
    UpdatedGravatarEvent.gravatarWithChanges: Some(MockEntities.gravatarEntity1),
    set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
    getOwner: Obj.magic,
  },
}->Obj.magic
