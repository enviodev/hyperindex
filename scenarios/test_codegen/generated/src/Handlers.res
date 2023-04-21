let getDefaultHandler: (string, 'a, 'b) => unit = (handlerName, _, _) => {
  Js.Console.warn(
    // TODO: link to our docs.
    `${handlerName} was not registered, ignoring event. Please register a handler for this event using the register${handlerName}.`,
  )
}

module GravatarContract = {
  %%private(
    let testEventLoadEntities = ref(None)
    let testEventHandler = ref(None)
    let newGravatarLoadEntities = ref(None)
    let newGravatarHandler = ref(None)
    let updatedGravatarLoadEntities = ref(None)
    let updatedGravatarHandler = ref(None)
  )

  let registerTestEventLoadEntities = (
    handler: (
      Types.eventLog<Types.GravatarContract.TestEventEvent.eventArgs>,
      Types.GravatarContract.TestEventEvent.loaderContext,
    ) => unit,
  ) => {
    testEventLoadEntities := Some(handler)
  }
  let registerNewGravatarLoadEntities = (
    handler: (
      Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
      Types.GravatarContract.NewGravatarEvent.loaderContext,
    ) => unit,
  ) => {
    newGravatarLoadEntities := Some(handler)
  }
  let registerUpdatedGravatarLoadEntities = (
    handler: (
      Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
      Types.GravatarContract.UpdatedGravatarEvent.loaderContext,
    ) => unit,
  ) => {
    updatedGravatarLoadEntities := Some(handler)
  }

  let registerTestEventHandler = (
    handler: (
      Types.eventLog<Types.GravatarContract.TestEventEvent.eventArgs>,
      Types.GravatarContract.TestEventEvent.context,
    ) => unit,
  ) => {
    testEventHandler := Some(handler)
  }
  let registerNewGravatarHandler = (
    handler: (
      Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
      Types.GravatarContract.NewGravatarEvent.context,
    ) => unit,
  ) => {
    newGravatarHandler := Some(handler)
  }
  let registerUpdatedGravatarHandler = (
    handler: (
      Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
      Types.GravatarContract.UpdatedGravatarEvent.context,
    ) => unit,
  ) => {
    updatedGravatarHandler := Some(handler)
  }

  let getTestEventLoadEntities = () =>
    testEventLoadEntities.contents->Belt.Option.getWithDefault(
      getDefaultHandler("testEventLoadEntities"),
    )
  let getNewGravatarLoadEntities = () =>
    newGravatarLoadEntities.contents->Belt.Option.getWithDefault(
      getDefaultHandler("newGravatarLoadEntities"),
    )
  let getUpdatedGravatarLoadEntities = () =>
    updatedGravatarLoadEntities.contents->Belt.Option.getWithDefault(
      getDefaultHandler("updatedGravatarLoadEntities"),
    )

  let getTestEventHandler = () =>
    testEventHandler.contents->Belt.Option.getWithDefault(getDefaultHandler("testEventHandler"))
  let getNewGravatarHandler = () =>
    newGravatarHandler.contents->Belt.Option.getWithDefault(getDefaultHandler("newGravatarHandler"))
  let getUpdatedGravatarHandler = () =>
    updatedGravatarHandler.contents->Belt.Option.getWithDefault(
      getDefaultHandler("updatedGravatarHandler"),
    )
}
