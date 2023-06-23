let setMock = Sinon.stub()

let mockNewGravatarContext: Types.GravatarContract.NewGravatarEvent.context = {
  gravatar: {
    set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}

let mockUpdateGravatarContext: Types.GravatarContract.UpdatedGravatarEvent.context = {
  gravatar: {
    gravatarWithChanges: () => Some(MockEntities.gravatarEntity1),
    set: gravatarSet => {
      setMock->Sinon.callStub1(gravatarSet.id)
    },
    delete: _id => Js.log("inimplemented delete"),
  },
}
