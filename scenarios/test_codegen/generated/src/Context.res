module GravatarContract = {
  module NewGravatarEvent = {
    type context = Types.GravatarContract.NewGravatarEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.NewGravatarEvent.loaderContext,
      getContext: unit => Types.GravatarContract.NewGravatarEvent.context,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      // TODO: loop through each of the named arguments.
      let optIdOf_gravatarWithChanges = ref(None)

      let loaderContext: Types.GravatarContract.NewGravatarEvent.loaderContext = {
        // TODO: loop through each of the named arguments.
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id) => {
            optIdOf_gravatarWithChanges := Some(id)
          },
        },
      }
      {
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
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      // TODO: loop through each of the named arguments.
      let optIdOf_gravatarWithChanges = ref(None)

      let loaderContext: Types.GravatarContract.UpdatedGravatarEvent.loaderContext = {
        // TODO: loop through each of the named arguments.
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id) => {
            optIdOf_gravatarWithChanges := Some(id)
          },
        },
      }
      {
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
