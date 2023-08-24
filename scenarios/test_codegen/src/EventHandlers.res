open Types

Handlers.GravatarContract.NewGravatar.loader((~event, ~context) => {
  ()
})

Handlers.GravatarContract.NewGravatar.handler((~event, ~context) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: Ethers.BigInt.fromInt(1),
  }

  context.gravatar.set(gravatarObject)
})

Handlers.GravatarContract.UpdatedGravatar.loader((~event, ~context) => {
  context.gravatar.gravatarWithChangesLoad(
    ~loaders={loadOwner: {}},
    event.params.id->Ethers.BigInt.toString,
  )
})

Handlers.GravatarContract.UpdatedGravatar.handler((~event, ~context) => {
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
    context.gravatar.gravatarWithChanges->Belt.Option.mapWithDefault(
      Ethers.BigInt.fromInt(1),
      gravatar => gravatar.updatesCount->Ethers.BigInt.add(Ethers.BigInt.fromInt(1)),
    )
  // Js.log("HANDLER I CARE ABOUT! context")
  // Js.log(context)
  // Js.log("context.log")
  // Js.log(context.log)

  let gravatar: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.set(gravatar)
})
