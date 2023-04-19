module GravatarContract = {
  module NewGravatarEvent = {
    type context = Types.GravatarContract.NewGravatarEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.NewGravatarEvent.loaderContext,
      getContext: unit => Types.GravatarContract.NewGravatarEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      // TODO: loop through each of the named arguments.
      let optIdOf_gravatarWithChanges = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.NewGravatarEvent.loaderContext = {
        // TODO: loop through each of the named arguments.
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id) => {
            optIdOf_gravatarWithChanges := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.GravatarRead(id))
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: () => {
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Create)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Update)
            },
            delete: id => (),
            //TODO hardcoded - retrieve from config.yaml
            gravatarWithChanges: () =>
              optIdOf_gravatarWithChanges.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.Gravatar.getGravatar(~id)
              ),
          },
        },
      }
    }
  }
  module UpdatedGravatarEvent = {
    type context = Types.GravatarContract.UpdatedGravatarEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.UpdatedGravatarEvent.loaderContext,
      getContext: unit => Types.GravatarContract.UpdatedGravatarEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      // TODO: loop through each of the named arguments.
      let optIdOf_gravatarWithChanges = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.UpdatedGravatarEvent.loaderContext = {
        // TODO: loop through each of the named arguments.
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id) => {
            optIdOf_gravatarWithChanges := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.GravatarRead(id))
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: () => {
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Create)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~gravatar=entity, ~crud=Types.Update)
            },
            delete: id => (),
            //TODO hardcoded - retrieve from config.yaml
            gravatarWithChanges: () =>
              optIdOf_gravatarWithChanges.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.Gravatar.getGravatar(~id)
              ),
          },
        },
      }
    }
  }
}
