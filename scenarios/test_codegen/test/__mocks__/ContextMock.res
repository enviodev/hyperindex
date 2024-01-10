open Types.GravatarContract

let setMock = Sinon.stub()

let mockNewGravatarHandlerContext: NewGravatarEvent.handlerContext = {
  //note the js use uppercased even though the rescript context is lower case gravatar due to @as
  "Gravatar": {
    NewGravatarEvent.set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}->Obj.magic

let mockNewGravatarContext: Context.GravatarContract.NewGravatarEvent.context = {
  "getHandlerContextSync": () => mockNewGravatarHandlerContext,
}->Obj.magic

let mockUpdateGravatarHandlerContext: UpdatedGravatarEvent.handlerContext = {
  "log": {
    "debug": Js.log,
    "info": Js.log,
    "warn": Js.log,
    "error": Js.log,
    "errorWithExn": Js.log2,
  },
  "Gravatar": (
    {
      gravatarWithChanges: Some(MockEntities.gravatarEntity1),
      set: gravatarSet => {
        setMock->Sinon.callStub1(gravatarSet.id)
      },
      delete: _id => Js.log("inimplemented delete"),
      getOwner: Obj.magic,
      get: _id => Some(MockEntities.gravatarEntity1),
    }: UpdatedGravatarEvent.gravatarEntityHandlerContext
  ),
}->Obj.magic

let mockUpdateGravatarContext: Context.GravatarContract.UpdatedGravatarEvent.context = {
  "getHandlerContextSync": () => mockUpdateGravatarHandlerContext,
}->Obj.magic
