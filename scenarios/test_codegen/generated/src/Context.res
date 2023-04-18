module GravatarContract = {
  module NewGravatarEvent = {
    type context = Types.GravatarContract.NewGravatarEvent.context

    %%private(
      let context: context = {
        gravatar: {
          insert: entity => {
            IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Create)
          },
          update: entity => {
            IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Update)
          },
          delete: id => (),
          //TODO hardcoded - retrieve from config.yaml
          gravatarWithChanges: () => Obj.magic(),
        },
      }
    )
    let getContext: unit => context = () => context
    let getLoaderContext: unit => Types.GravatarContract.UpdatedGravatarEvent.loaderContext =
      ()->Obj.magic
  }
  module UpdatedGravatarEvent = {
    type context = Types.GravatarContract.UpdatedGravatarEvent.context

    %%private(
      let context: context = {
        gravatar: {
          insert: entity => {
            IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Create)
          },
          update: entity => {
            IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Update)
          },
          delete: id => (),
          //TODO hardcoded - retrieve from config.yaml
          gravatarWithChanges: () => Obj.magic(),
        },
      }
    )
    let getContext: unit => context = () => context
    let getLoaderContext: unit => Types.GravatarContract.UpdatedGravatarEvent.loaderContext =
      ()->Obj.magic
  }
}

/*
open Types

module GravatarContract = {
  module NewGravatarEvent = {

    %%private(
      let context: context = {
        gravatar: {
          insert: entity => (),
          update: entity => (),
          delete: id => (),
        },
      }
    )

    let getContext: unit => context = () => context
  }
  module UpdatedGravatarEvent = {
    type context = Types.GravatarContract.UpdatedGravatarTypes.context

    %%private(
      let context: context = {
        gravatar: {
          gravatarWithChanges: () => Obj.magic(), 
          insert: entity => {IO.InMemoryStore.Gravatar.setGravatar(~gravatar = entity, ~crud = Types.Create)},
          update: entity => {IO.InMemoryStore.Gravatar.setGravatar(~gravatar = entity, ~crud = Types.Update)},
          delete: id => (),
        },
      }
    )

    let getContext: unit => context = () => context
  }
}
 */
