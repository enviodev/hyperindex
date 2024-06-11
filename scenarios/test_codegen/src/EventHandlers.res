open Types

Handlers.GravatarContract.NewGravatar.handler(async ({event, context}) => {
  let gravatarSize: Enums.gravatarSize = SMALL
  let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner_id: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: Ethers.BigInt.fromInt(1),
    size: gravatarSize,
  }

  context.gravatar.set(gravatarObject)
})

Handlers.GravatarContract.UpdatedGravatar.register({
  preLoader: ({event, context}) => {
    context.gravatar.get(event.params.id->Ethers.BigInt.toString)
  },
  handler: async ({event, context, preLoaderReturn}) => {
    /// Some examples of user logging
    context.log.debug(`We are processing the event, ${event.blockHash} (debug)`)
    context.log.info(`We are processing the event, ${event.blockHash} (info)`)
    context.log.warn(`We are processing the event, ${event.blockHash} (warn)`)
    context.log.error(`We are processing the event, ${event.blockHash} (error)`)

    // Some examples of user logging not using strings
    context.log->Logs.debug({
      "msg": "We are processing the event",
      "type": "debug",
      "data": {"blockHash": event.blockHash},
    })
    context.log->Logs.info({
      "msg": "We are processing the event",
      "type": "info",
      "data": {"blockHash": event.blockHash},
    })
    context.log->Logs.warn({
      "msg": "We are processing the event",
      "type": "warn",
      "data": {"blockHash": event.blockHash},
    })
    context.log->Logs.error({
      "msg": "We are processing the event",
      "type": "error",
      "data": {"blockHash": event.blockHash},
    })
    exception ExampleException(string)
    context.log->Logs.errorWithExn(
      ExampleException("some error processing the event")->Js.Exn.asJsExn,
      {
        "msg": "We are processing the event",
        "type": "error",
        "data": {"blockHash": event.blockHash},
      },
    )

    let updatesCount =
      preLoaderReturn->Belt.Option.mapWithDefault(Ethers.BigInt.fromInt(1), gravatar =>
        gravatar.Entities.Gravatar.updatesCount->Ethers.BigInt.add(Ethers.BigInt.fromInt(1))
      )

    let gravatarSize: Enums.gravatarSize = MEDIUM
    let gravatar: gravatarEntity = {
      id: event.params.id->Ethers.BigInt.toString,
      owner_id: event.params.owner->Ethers.ethAddressToString,
      displayName: event.params.displayName,
      imageUrl: event.params.imageUrl,
      updatesCount,
      size: gravatarSize,
    }

    if event.params.id->Ethers.BigInt.toString == "1001" {
      context.log.info("id matched, deleting gravatar 1004")
      context.gravatar.deleteUnsafe("1004")
    }

    context.gravatar.set(gravatar)
  },
})

let aIdWithGrandChildC = "aIdWithGrandChildC"
let aIdWithNoGrandChildC = "aIdWithNoGrandChildC"

Handlers.GravatarContract.TestEventThatCopiesBigIntViaLinkedEntities.handler(async ({context}) => {
  let copyStringFromGrandchildIfAvailable = async (idOfGrandparent: Types.id) =>
    switch await context.a.get(idOfGrandparent) {
    | Some(a) =>
      let optB = await context.b.get(a.b_id)

      switch optB->Belt.Option.flatMap(b => b.c_id) {
      | Some(c_id) =>
        switch await context.c.get(c_id) {
        | Some(cWithText) =>
          context.a.set({
            ...a,
            optionalStringToTestLinkedEntities: Some(cWithText.stringThatIsMirroredToA),
          })
        | None => ()
        }
      | None => ()
      }
    | None => ()
    }

  await copyStringFromGrandchildIfAvailable(aIdWithGrandChildC)
  await copyStringFromGrandchildIfAvailable(aIdWithNoGrandChildC)
})
