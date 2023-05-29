module GravatarContract = {
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
          nftcollection: {
            insert: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Create,
                ~eventData,
              )
            },
            update: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Update,
                ~eventData,
              )
            },
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(nftcollection) with ID ${id}.`,
              ),
          },
          token: {
            insert: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
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

      @warning("-16")
      let loaderContext: Types.GravatarContract.UpdatedGravatarEvent.loaderContext = {
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id, ~loaders={}) => {
            optIdOf_gravatarWithChanges := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.GravatarRead(id, loaders))
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
            getOwner: gravatar => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=gravatar.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Gravatar owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateGravatar entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          nftcollection: {
            insert: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Create,
                ~eventData,
              )
            },
            update: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Update,
                ~eventData,
              )
            },
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(nftcollection) with ID ${id}.`,
              ),
          },
          token: {
            insert: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
          },
        },
      }
    }
  }
}
module NftFactoryContract = {
  module SimpleNftCreatedEvent = {
    type context = Types.NftFactoryContract.SimpleNftCreatedEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.NftFactoryContract.SimpleNftCreatedEvent.loaderContext,
      getContext: (
        ~eventData: Types.eventData,
      ) => Types.NftFactoryContract.SimpleNftCreatedEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.NftFactoryContract.SimpleNftCreatedEvent.loaderContext = {}
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
          nftcollection: {
            insert: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Create,
                ~eventData,
              )
            },
            update: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Update,
                ~eventData,
              )
            },
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(nftcollection) with ID ${id}.`,
              ),
          },
          token: {
            insert: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
          },
        },
      }
    }
  }
}
module SimpleNftContract = {
  module TransferEvent = {
    type context = Types.SimpleNftContract.TransferEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.SimpleNftContract.TransferEvent.loaderContext,
      getContext: (~eventData: Types.eventData) => Types.SimpleNftContract.TransferEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
    }
    let contextCreator: unit => contextCreatorFunctions = () => {
      let optIdOf_userFrom = ref(None)
      let optIdOf_userTo = ref(None)
      let optIdOf_nftCollectionUpdated = ref(None)
      let optIdOf_existingTransferredToken = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let loaderContext: Types.SimpleNftContract.TransferEvent.loaderContext = {
        user: {
          userFromLoad: (id: Types.id) => {
            optIdOf_userFrom := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.UserRead(id))
          },
          userToLoad: (id: Types.id) => {
            optIdOf_userTo := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.UserRead(id))
          },
        },
        nftcollection: {
          nftCollectionUpdatedLoad: (id: Types.id) => {
            optIdOf_nftCollectionUpdated := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.NftcollectionRead(id))
          },
        },
        token: {
          existingTransferredTokenLoad: (id: Types.id) => {
            optIdOf_existingTransferredToken := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.TokenRead(id))
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
            userFrom: () =>
              optIdOf_userFrom.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.User.getUser(~id)
              ),
            userTo: () =>
              optIdOf_userTo.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.User.getUser(~id)
              ),
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
          nftcollection: {
            insert: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Create,
                ~eventData,
              )
            },
            update: entity => {
              IO.InMemoryStore.Nftcollection.setNftcollection(
                ~entity,
                ~crud=Types.Update,
                ~eventData,
              )
            },
            delete: id =>
              Js.Console.warn(
                `[unimplemented delete] can't delete entity(nftcollection) with ID ${id}.`,
              ),
            nftCollectionUpdated: () =>
              optIdOf_nftCollectionUpdated.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.Nftcollection.getNftcollection(~id)
              ),
          },
          token: {
            insert: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Token.setToken(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Js.Console.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            existingTransferredToken: () =>
              optIdOf_existingTransferredToken.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.Token.getToken(~id)
              ),
          },
        },
      }
    }
  }
}
