module GravatarContract = {
  module NewGravatarEvent = {
    type context = Types.GravatarContract.NewGravatarEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.NewGravatarEvent.loaderContext,
      getContext: unit => Types.GravatarContract.NewGravatarEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.NewGravatarEvent.loaderContext = {}
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
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`,
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
      let optIdOf_gravatarWithChanges = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.UpdatedGravatarEvent.loaderContext = {
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
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`,
              ),
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
