module GravatarContract = {
  module TestEventEvent = {
    type context = Types.GravatarContract.TestEventEvent.context

    type contextCreatorFunctions = {
      getLoaderContext: unit => Types.GravatarContract.TestEventEvent.loaderContext,
      getContext: (~eventData: Types.eventData) => Types.GravatarContract.TestEventEvent.context,
      getEntitiesToLoad: unit => array<Types.entityRead>,
      getAddedDynamicContractRegistrations: unit => array<Types.dynamicContractRegistryEntity>,
    }
    let contextCreator: (~chainId: int, ~event: Types.eventLog<'a>) => contextCreatorFunctions = (
      ~chainId,
      ~event,
    ) => {
      let optIdOf_testingA = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let addedDynamicContractRegistrations: array<Types.dynamicContractRegistryEntity> = []

      @warning("-16")
      let loaderContext: Types.GravatarContract.TestEventEvent.loaderContext = {
        contractRegistration: {
          //TODO only add contracts we've registered for the event in the config
          addGravatar: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "Gravatar",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="Gravatar",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addNftFactory: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "NftFactory",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="NftFactory",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addSimpleNft: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "SimpleNft",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="SimpleNft",
            )
          },
        },
        a: {
          testingALoad: (id: Types.id, ~loaders={}) => {
            optIdOf_testingA := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.ARead(id, loaders))
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getAddedDynamicContractRegistrations: () => addedDynamicContractRegistrations,
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
              Logging.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
            getGravatar: user => {
              let optGravatar =
                user.gravatar->Belt.Option.map(entityFieldId =>
                  IO.InMemoryStore.Gravatar.getGravatar(~id=entityFieldId)
                )
              switch optGravatar {
              | Some(gravatar) => gravatar
              | None =>
                Logging.warn(`User gravatar data not found. Loading associated gravatar from database.
Please consider loading the gravatar in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a gravatar with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getTokens: user => {
              let tokensArray = user.tokens->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.Token.getToken(~id=entityId)

                switch optEntity {
                | Some(tokens) => tokens
                | None =>
                  Logging.warn(`User tokens data not found. Loading associated token from database.
Please consider loading the token in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a token with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              tokensArray
            },
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`),
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
              Logging.warn(
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
              Logging.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            getCollection: token => {
              let optCollection = IO.InMemoryStore.Nftcollection.getNftcollection(
                ~id=token.collection,
              )
              switch optCollection {
              | Some(collection) => collection
              | None =>
                Logging.warn(`Token collection data not found. Loading associated nftcollection from database.
Please consider loading the nftcollection in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a nftcollection with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getOwner: token => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=token.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Token owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          a: {
            insert: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(a) with ID ${id}.`),
            testingA: () =>
              optIdOf_testingA.contents->Belt.Option.flatMap(id => IO.InMemoryStore.A.getA(~id)),
            getB: a => {
              let optB = IO.InMemoryStore.B.getB(~id=a.b)
              switch optB {
              | Some(b) => b
              | None =>
                Logging.warn(`A b data not found. Loading associated b from database.
Please consider loading the b in the UpdateA entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a b with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          b: {
            insert: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(b) with ID ${id}.`),
            getA: b => {
              let aArray = b.a->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.A.getA(~id=entityId)

                switch optEntity {
                | Some(a) => a
                | None =>
                  Logging.warn(`B a data not found. Loading associated a from database.
Please consider loading the a in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              aArray
            },
            getC: b => {
              let optC =
                b.c->Belt.Option.map(entityFieldId => IO.InMemoryStore.C.getC(~id=entityFieldId))
              switch optC {
              | Some(c) => c
              | None =>
                Logging.warn(`B c data not found. Loading associated c from database.
Please consider loading the c in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a c with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          c: {
            insert: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(c) with ID ${id}.`),
            getA: c => {
              let optA = IO.InMemoryStore.A.getA(~id=c.a)
              switch optA {
              | Some(a) => a
              | None =>
                Logging.warn(`C a data not found. Loading associated a from database.
Please consider loading the a in the UpdateC entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
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
      getAddedDynamicContractRegistrations: unit => array<Types.dynamicContractRegistryEntity>,
    }
    let contextCreator: (~chainId: int, ~event: Types.eventLog<'a>) => contextCreatorFunctions = (
      ~chainId,
      ~event,
    ) => {
      let entitiesToLoad: array<Types.entityRead> = []

      let addedDynamicContractRegistrations: array<Types.dynamicContractRegistryEntity> = []

      @warning("-16")
      let loaderContext: Types.GravatarContract.NewGravatarEvent.loaderContext = {
        contractRegistration: {
          //TODO only add contracts we've registered for the event in the config
          addGravatar: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "Gravatar",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="Gravatar",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addNftFactory: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "NftFactory",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="NftFactory",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addSimpleNft: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "SimpleNft",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="SimpleNft",
            )
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getAddedDynamicContractRegistrations: () => addedDynamicContractRegistrations,
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
              Logging.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
            getGravatar: user => {
              let optGravatar =
                user.gravatar->Belt.Option.map(entityFieldId =>
                  IO.InMemoryStore.Gravatar.getGravatar(~id=entityFieldId)
                )
              switch optGravatar {
              | Some(gravatar) => gravatar
              | None =>
                Logging.warn(`User gravatar data not found. Loading associated gravatar from database.
Please consider loading the gravatar in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a gravatar with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getTokens: user => {
              let tokensArray = user.tokens->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.Token.getToken(~id=entityId)

                switch optEntity {
                | Some(tokens) => tokens
                | None =>
                  Logging.warn(`User tokens data not found. Loading associated token from database.
Please consider loading the token in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a token with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              tokensArray
            },
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`),
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
              Logging.warn(
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
              Logging.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            getCollection: token => {
              let optCollection = IO.InMemoryStore.Nftcollection.getNftcollection(
                ~id=token.collection,
              )
              switch optCollection {
              | Some(collection) => collection
              | None =>
                Logging.warn(`Token collection data not found. Loading associated nftcollection from database.
Please consider loading the nftcollection in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a nftcollection with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getOwner: token => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=token.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Token owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          a: {
            insert: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(a) with ID ${id}.`),
            getB: a => {
              let optB = IO.InMemoryStore.B.getB(~id=a.b)
              switch optB {
              | Some(b) => b
              | None =>
                Logging.warn(`A b data not found. Loading associated b from database.
Please consider loading the b in the UpdateA entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a b with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          b: {
            insert: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(b) with ID ${id}.`),
            getA: b => {
              let aArray = b.a->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.A.getA(~id=entityId)

                switch optEntity {
                | Some(a) => a
                | None =>
                  Logging.warn(`B a data not found. Loading associated a from database.
Please consider loading the a in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              aArray
            },
            getC: b => {
              let optC =
                b.c->Belt.Option.map(entityFieldId => IO.InMemoryStore.C.getC(~id=entityFieldId))
              switch optC {
              | Some(c) => c
              | None =>
                Logging.warn(`B c data not found. Loading associated c from database.
Please consider loading the c in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a c with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          c: {
            insert: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(c) with ID ${id}.`),
            getA: c => {
              let optA = IO.InMemoryStore.A.getA(~id=c.a)
              switch optA {
              | Some(a) => a
              | None =>
                Logging.warn(`C a data not found. Loading associated a from database.
Please consider loading the a in the UpdateC entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
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
      getAddedDynamicContractRegistrations: unit => array<Types.dynamicContractRegistryEntity>,
    }
    let contextCreator: (~chainId: int, ~event: Types.eventLog<'a>) => contextCreatorFunctions = (
      ~chainId,
      ~event,
    ) => {
      let optIdOf_gravatarWithChanges = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let addedDynamicContractRegistrations: array<Types.dynamicContractRegistryEntity> = []

      @warning("-16")
      let loaderContext: Types.GravatarContract.UpdatedGravatarEvent.loaderContext = {
        contractRegistration: {
          //TODO only add contracts we've registered for the event in the config
          addGravatar: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "Gravatar",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="Gravatar",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addNftFactory: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "NftFactory",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="NftFactory",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addSimpleNft: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "SimpleNft",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="SimpleNft",
            )
          },
        },
        gravatar: {
          gravatarWithChangesLoad: (id: Types.id, ~loaders={}) => {
            optIdOf_gravatarWithChanges := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.GravatarRead(id, loaders))
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getAddedDynamicContractRegistrations: () => addedDynamicContractRegistrations,
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
              Logging.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
            getGravatar: user => {
              let optGravatar =
                user.gravatar->Belt.Option.map(entityFieldId =>
                  IO.InMemoryStore.Gravatar.getGravatar(~id=entityFieldId)
                )
              switch optGravatar {
              | Some(gravatar) => gravatar
              | None =>
                Logging.warn(`User gravatar data not found. Loading associated gravatar from database.
Please consider loading the gravatar in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a gravatar with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getTokens: user => {
              let tokensArray = user.tokens->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.Token.getToken(~id=entityId)

                switch optEntity {
                | Some(tokens) => tokens
                | None =>
                  Logging.warn(`User tokens data not found. Loading associated token from database.
Please consider loading the token in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a token with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              tokensArray
            },
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`),
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
              Logging.warn(
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
              Logging.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            getCollection: token => {
              let optCollection = IO.InMemoryStore.Nftcollection.getNftcollection(
                ~id=token.collection,
              )
              switch optCollection {
              | Some(collection) => collection
              | None =>
                Logging.warn(`Token collection data not found. Loading associated nftcollection from database.
Please consider loading the nftcollection in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a nftcollection with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getOwner: token => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=token.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Token owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          a: {
            insert: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(a) with ID ${id}.`),
            getB: a => {
              let optB = IO.InMemoryStore.B.getB(~id=a.b)
              switch optB {
              | Some(b) => b
              | None =>
                Logging.warn(`A b data not found. Loading associated b from database.
Please consider loading the b in the UpdateA entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a b with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          b: {
            insert: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(b) with ID ${id}.`),
            getA: b => {
              let aArray = b.a->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.A.getA(~id=entityId)

                switch optEntity {
                | Some(a) => a
                | None =>
                  Logging.warn(`B a data not found. Loading associated a from database.
Please consider loading the a in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              aArray
            },
            getC: b => {
              let optC =
                b.c->Belt.Option.map(entityFieldId => IO.InMemoryStore.C.getC(~id=entityFieldId))
              switch optC {
              | Some(c) => c
              | None =>
                Logging.warn(`B c data not found. Loading associated c from database.
Please consider loading the c in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a c with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          c: {
            insert: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(c) with ID ${id}.`),
            getA: c => {
              let optA = IO.InMemoryStore.A.getA(~id=c.a)
              switch optA {
              | Some(a) => a
              | None =>
                Logging.warn(`C a data not found. Loading associated a from database.
Please consider loading the a in the UpdateC entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
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
      getAddedDynamicContractRegistrations: unit => array<Types.dynamicContractRegistryEntity>,
    }
    let contextCreator: (~chainId: int, ~event: Types.eventLog<'a>) => contextCreatorFunctions = (
      ~chainId,
      ~event,
    ) => {
      let entitiesToLoad: array<Types.entityRead> = []

      let addedDynamicContractRegistrations: array<Types.dynamicContractRegistryEntity> = []

      @warning("-16")
      let loaderContext: Types.NftFactoryContract.SimpleNftCreatedEvent.loaderContext = {
        contractRegistration: {
          //TODO only add contracts we've registered for the event in the config
          addGravatar: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "Gravatar",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="Gravatar",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addNftFactory: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "NftFactory",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="NftFactory",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addSimpleNft: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "SimpleNft",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="SimpleNft",
            )
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getAddedDynamicContractRegistrations: () => addedDynamicContractRegistrations,
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
              Logging.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
            getGravatar: user => {
              let optGravatar =
                user.gravatar->Belt.Option.map(entityFieldId =>
                  IO.InMemoryStore.Gravatar.getGravatar(~id=entityFieldId)
                )
              switch optGravatar {
              | Some(gravatar) => gravatar
              | None =>
                Logging.warn(`User gravatar data not found. Loading associated gravatar from database.
Please consider loading the gravatar in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a gravatar with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getTokens: user => {
              let tokensArray = user.tokens->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.Token.getToken(~id=entityId)

                switch optEntity {
                | Some(tokens) => tokens
                | None =>
                  Logging.warn(`User tokens data not found. Loading associated token from database.
Please consider loading the token in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a token with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              tokensArray
            },
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`),
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
              Logging.warn(
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
              Logging.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            getCollection: token => {
              let optCollection = IO.InMemoryStore.Nftcollection.getNftcollection(
                ~id=token.collection,
              )
              switch optCollection {
              | Some(collection) => collection
              | None =>
                Logging.warn(`Token collection data not found. Loading associated nftcollection from database.
Please consider loading the nftcollection in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a nftcollection with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getOwner: token => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=token.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Token owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          a: {
            insert: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(a) with ID ${id}.`),
            getB: a => {
              let optB = IO.InMemoryStore.B.getB(~id=a.b)
              switch optB {
              | Some(b) => b
              | None =>
                Logging.warn(`A b data not found. Loading associated b from database.
Please consider loading the b in the UpdateA entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a b with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          b: {
            insert: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(b) with ID ${id}.`),
            getA: b => {
              let aArray = b.a->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.A.getA(~id=entityId)

                switch optEntity {
                | Some(a) => a
                | None =>
                  Logging.warn(`B a data not found. Loading associated a from database.
Please consider loading the a in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              aArray
            },
            getC: b => {
              let optC =
                b.c->Belt.Option.map(entityFieldId => IO.InMemoryStore.C.getC(~id=entityFieldId))
              switch optC {
              | Some(c) => c
              | None =>
                Logging.warn(`B c data not found. Loading associated c from database.
Please consider loading the c in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a c with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          c: {
            insert: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(c) with ID ${id}.`),
            getA: c => {
              let optA = IO.InMemoryStore.A.getA(~id=c.a)
              switch optA {
              | Some(a) => a
              | None =>
                Logging.warn(`C a data not found. Loading associated a from database.
Please consider loading the a in the UpdateC entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
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
      getAddedDynamicContractRegistrations: unit => array<Types.dynamicContractRegistryEntity>,
    }
    let contextCreator: (~chainId: int, ~event: Types.eventLog<'a>) => contextCreatorFunctions = (
      ~chainId,
      ~event,
    ) => {
      let optIdOf_userFrom = ref(None)
      let optIdOf_userTo = ref(None)
      let optIdOf_nftCollectionUpdated = ref(None)
      let optIdOf_existingTransferredToken = ref(None)

      let entitiesToLoad: array<Types.entityRead> = []

      let addedDynamicContractRegistrations: array<Types.dynamicContractRegistryEntity> = []

      @warning("-16")
      let loaderContext: Types.SimpleNftContract.TransferEvent.loaderContext = {
        contractRegistration: {
          //TODO only add contracts we've registered for the event in the config
          addGravatar: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "Gravatar",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="Gravatar",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addNftFactory: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "NftFactory",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="NftFactory",
            )
          },
          //TODO only add contracts we've registered for the event in the config
          addSimpleNft: (contractAddress: Ethers.ethAddress) => {
            let eventId = EventUtils.packEventIndex(
              ~blockNumber=event.blockNumber,
              ~logIndex=event.logIndex,
            )
            let dynamicContractRegistration: Types.dynamicContractRegistryEntity = {
              chainId,
              eventId,
              contractAddress,
              contractType: "SimpleNft",
            }

            addedDynamicContractRegistrations->Js.Array2.push(dynamicContractRegistration)->ignore

            IO.InMemoryStore.DynamicContractRegistry.setDynamicContractRegistry(
              ~entity=dynamicContractRegistration,
              ~crud=Types.Create,
            )

            Converters.ContractNameAddressMappings.addContractAddress(
              ~chainId,
              ~contractAddress,
              ~contractName="SimpleNft",
            )
          },
        },
        user: {
          userFromLoad: (id: Types.id, ~loaders={}) => {
            optIdOf_userFrom := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.UserRead(id, loaders))
          },
          userToLoad: (id: Types.id, ~loaders={}) => {
            optIdOf_userTo := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.UserRead(id, loaders))
          },
        },
        nftcollection: {
          nftCollectionUpdatedLoad: (id: Types.id) => {
            optIdOf_nftCollectionUpdated := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.NftcollectionRead(id))
          },
        },
        token: {
          existingTransferredTokenLoad: (id: Types.id, ~loaders={}) => {
            optIdOf_existingTransferredToken := Some(id)

            let _ = Js.Array2.push(entitiesToLoad, Types.TokenRead(id, loaders))
          },
        },
      }
      {
        getEntitiesToLoad: () => entitiesToLoad,
        getAddedDynamicContractRegistrations: () => addedDynamicContractRegistrations,
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
              Logging.warn(`[unimplemented delete] can't delete entity(user) with ID ${id}.`),
            userFrom: () =>
              optIdOf_userFrom.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.User.getUser(~id)
              ),
            userTo: () =>
              optIdOf_userTo.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.User.getUser(~id)
              ),
            getGravatar: user => {
              let optGravatar =
                user.gravatar->Belt.Option.map(entityFieldId =>
                  IO.InMemoryStore.Gravatar.getGravatar(~id=entityFieldId)
                )
              switch optGravatar {
              | Some(gravatar) => gravatar
              | None =>
                Logging.warn(`User gravatar data not found. Loading associated gravatar from database.
Please consider loading the gravatar in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a gravatar with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getTokens: user => {
              let tokensArray = user.tokens->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.Token.getToken(~id=entityId)

                switch optEntity {
                | Some(tokens) => tokens
                | None =>
                  Logging.warn(`User tokens data not found. Loading associated token from database.
Please consider loading the token in the UpdateUser entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a token with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              tokensArray
            },
          },
          gravatar: {
            insert: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Create, ~eventData)
            },
            update: entity => {
              IO.InMemoryStore.Gravatar.setGravatar(~entity, ~crud=Types.Update, ~eventData)
            },
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(gravatar) with ID ${id}.`),
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
              Logging.warn(
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
              Logging.warn(`[unimplemented delete] can't delete entity(token) with ID ${id}.`),
            existingTransferredToken: () =>
              optIdOf_existingTransferredToken.contents->Belt.Option.flatMap(id =>
                IO.InMemoryStore.Token.getToken(~id)
              ),
            getCollection: token => {
              let optCollection = IO.InMemoryStore.Nftcollection.getNftcollection(
                ~id=token.collection,
              )
              switch optCollection {
              | Some(collection) => collection
              | None =>
                Logging.warn(`Token collection data not found. Loading associated nftcollection from database.
Please consider loading the nftcollection in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a nftcollection with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
            getOwner: token => {
              let optOwner = IO.InMemoryStore.User.getUser(~id=token.owner)
              switch optOwner {
              | Some(owner) => owner
              | None =>
                Logging.warn(`Token owner data not found. Loading associated user from database.
Please consider loading the user in the UpdateToken entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a user with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          a: {
            insert: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.A.setA(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(a) with ID ${id}.`),
            getB: a => {
              let optB = IO.InMemoryStore.B.getB(~id=a.b)
              switch optB {
              | Some(b) => b
              | None =>
                Logging.warn(`A b data not found. Loading associated b from database.
Please consider loading the b in the UpdateA entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a b with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          b: {
            insert: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.B.setB(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(b) with ID ${id}.`),
            getA: b => {
              let aArray = b.a->Belt.Array.map(entityId => {
                let optEntity = IO.InMemoryStore.A.getA(~id=entityId)

                switch optEntity {
                | Some(a) => a
                | None =>
                  Logging.warn(`B a data not found. Loading associated a from database.
Please consider loading the a in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                  // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                  "NOT_IMPLEMENTED_YET"->Obj.magic
                }
              })
              aArray
            },
            getC: b => {
              let optC =
                b.c->Belt.Option.map(entityFieldId => IO.InMemoryStore.C.getC(~id=entityFieldId))
              switch optC {
              | Some(c) => c
              | None =>
                Logging.warn(`B c data not found. Loading associated c from database.
Please consider loading the c in the UpdateB entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a c with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
          c: {
            insert: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Create, ~eventData)},
            update: entity => {IO.InMemoryStore.C.setC(~entity, ~crud=Types.Update, ~eventData)},
            delete: id =>
              Logging.warn(`[unimplemented delete] can't delete entity(c) with ID ${id}.`),
            getA: c => {
              let optA = IO.InMemoryStore.A.getA(~id=c.a)
              switch optA {
              | Some(a) => a
              | None =>
                Logging.warn(`C a data not found. Loading associated a from database.
Please consider loading the a in the UpdateC entity loader to greatly improve sync speed of your application.
`)
                // TODO: this isn't implemented yet. We should fetch a a with this ID from the database.
                "NOT_IMPLEMENTED_YET"->Obj.magic
              }
            },
          },
        },
      }
    }
  }
}
