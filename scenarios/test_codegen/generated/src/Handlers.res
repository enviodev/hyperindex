let getDefaultHandler: (string, ~event: 'a, ~context: 'b) => unit = (
  handlerName,
  ~event as _,
  ~context as _,
) => {
  Js.Console.warn(
    // TODO: link to our docs.
    `${handlerName} was not registered, ignoring event. Please register a handler for this event using the register${handlerName}.`,
  )
}

module GravatarContract = {
  %%private(
    let newGravatarLoadEntities = ref(None)
    let newGravatarHandler = ref(None)
    let updatedGravatarLoadEntities = ref(None)
    let updatedGravatarHandler = ref(None)
  )

  @genType
  let registerNewGravatarLoadEntities = (
    handler: (
      ~event: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
      ~context: Types.GravatarContract.NewGravatarEvent.loaderContext,
    ) => unit,
  ) => {
    newGravatarLoadEntities := Some(handler)
  }
  @genType
  let registerUpdatedGravatarLoadEntities = (
    handler: (
      ~event: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
      ~context: Types.GravatarContract.UpdatedGravatarEvent.loaderContext,
    ) => unit,
  ) => {
    updatedGravatarLoadEntities := Some(handler)
  }

  @genType
  let registerNewGravatarHandler = (
    handler: (
      ~event: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
      ~context: Types.GravatarContract.NewGravatarEvent.context,
    ) => unit,
  ) => {
    newGravatarHandler := Some(handler)
  }
  @genType
  let registerUpdatedGravatarHandler = (
    handler: (
      ~event: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
      ~context: Types.GravatarContract.UpdatedGravatarEvent.context,
    ) => unit,
  ) => {
    updatedGravatarHandler := Some(handler)
  }

  let getNewGravatarLoadEntities = () =>
    newGravatarLoadEntities.contents->Belt.Option.getWithDefault(
      getDefaultHandler("newGravatarLoadEntities"),
    )
  let getUpdatedGravatarLoadEntities = () =>
    updatedGravatarLoadEntities.contents->Belt.Option.getWithDefault(
      getDefaultHandler("updatedGravatarLoadEntities"),
    )

  let getNewGravatarHandler = () =>
    newGravatarHandler.contents->Belt.Option.getWithDefault(getDefaultHandler("newGravatarHandler"))
  let getUpdatedGravatarHandler = () =>
    updatedGravatarHandler.contents->Belt.Option.getWithDefault(
      getDefaultHandler("updatedGravatarHandler"),
    )
}
