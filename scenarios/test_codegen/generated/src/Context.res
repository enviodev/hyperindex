module GravatarContract = {
  module TestEventEvent = {
    type context = Types.GravatarContract.TestEventEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.TestEventEvent.loaderContext,
      getContext: (~eventData: Types.eventData) => Types.GravatarContract.TestEventEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.TestEventEvent.loaderContext = {}
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: (~eventData) => {
          user: {
            insert: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
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
  module NewGravatarEvent = {
    type context = Types.GravatarContract.NewGravatarEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.NewGravatarEvent.loaderContext,
      getContext: (~eventData: Types.eventData) => Types.GravatarContract.NewGravatarEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.GravatarContract.NewGravatarEvent.loaderContext = {}
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getLoaderContext: () => loaderContext,
        getContext: (~eventData) => {
          user: {
            insert: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
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
      getContext: (
        ~eventData: Types.eventData,
      ) => Types.GravatarContract.UpdatedGravatarEvent.context,
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
        getContext: (~eventData) => {
          user: {
            insert: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.User.setUser(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
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
