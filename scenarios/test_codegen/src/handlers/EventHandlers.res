// Test types

// Indexer type and value tests (compile-time type checking)
let _indexer: Indexer.indexer = Indexer.indexer
let _chain: Indexer.indexerChain = Indexer.getChainById(Indexer.indexer, #1)
let _chains: Indexer.indexerChains = Indexer.indexer.chains

// Compile-time test: getChainById has exhaustive pattern matching
// This ensures the function covers all chain IDs
let _testGetChainById = (chainId: Indexer.chainId) => Indexer.getChainById(Indexer.indexer, chainId)

let noopEffect = Envio.createEffect(
  {
    name: "noopEffect",
    input: S.literal(),
    output: S.literal(),
    rateLimit: Disable,
  },
  async ({input}) => {
    let () = input
  },
)

Indexer.Gravatar.NewGravatar.handler(async ({event, context}) => {
  let () = await context.effect(noopEffect, ())

  let gravatarSize: Enums.GravatarSize.t = SMALL
  let gravatarObject: Types.gravatar = {
    id: event.params.id->BigInt.toString,
    owner_id: event.params.owner->Address.toString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: BigInt.fromInt(1),
    size: gravatarSize,
  }

  context.gravatar.set(gravatarObject)
})

Indexer.Gravatar.UpdatedGravatar.handler(async ({event, context}) => {
  let maybeGravatar = await context.gravatar.get(event.params.id->BigInt.toString)

  /// Some examples of user logging
  context.log.debug(`We are processing the event, ${event.block.hash} (debug)`)
  context.log.info(`We are processing the event, ${event.block.hash} (info)`)
  context.log.warn(`We are processing the event, ${event.block.hash} (warn)`)
  context.log.error(`We are processing the event, ${event.block.hash} (error)`)

  // Some examples of user logging not using strings
  context.log.debug(
    "We are processing the event",
    ~params={
      "type": "debug",
      "data": {"blockHash": event.block.hash},
    },
  )
  context.log.info(
    "We are processing the event",
    ~params={
      "type": "info",
      "data": {"blockHash": event.block.hash},
    },
  )
  context.log.warn(
    "We are processing the event",
    ~params={
      "type": "warn",
      "data": {"blockHash": event.block.hash},
    },
  )
  context.log.error(
    "We are processing the event",
    ~params={
      "type": "error",
      "data": {"blockHash": event.block.hash},
    },
  )
  exception ExampleException(string)
  context.log.errorWithExn(
    "We are processing the event",
    ExampleException("some error processing the event"),
  )
  context.log.error(
    "We are processing the event",
    ~params={
      "type": "error",
      "data": {"blockHash": event.block.hash},
      "err": ExampleException("some error processing the event")->Js.Exn.asJsExn,
    },
  )

  let updatesCount =
    maybeGravatar->Belt.Option.mapWithDefault(BigInt.fromInt(1), gravatar =>
      gravatar.Entities.Gravatar.updatesCount->BigInt.add(BigInt.fromInt(1))
    )

  let gravatarSize: Enums.GravatarSize.t = MEDIUM
  let gravatar: Entities.Gravatar.t = {
    id: event.params.id->BigInt.toString,
    owner_id: event.params.owner->Address.toString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
    size: gravatarSize,
  }

  if event.params.id->BigInt.toString == "1001" {
    context.log.info("id matched, deleting gravatar 1004")
    context.gravatar.deleteUnsafe("1004")
  }

  context.gravatar.set(gravatar)
})

let aIdWithGrandChildC = "aIdWithGrandChildC"
let aIdWithNoGrandChildC = "aIdWithNoGrandChildC"

Indexer.Gravatar.TestEventThatCopiesBigIntViaLinkedEntities.handler(async ({context}) => {
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

// Generates modules for both TestEvent and TestEventWithCustomName
Indexer.Gravatar.TestEventWithCustomName.handler(async _ => {
  ()
})
Indexer.Gravatar.TestEvent.handler(async _ => {
  ()
})

// Test chain accessibility - exposed for testing
let lastEmptyEventChain: ref<option<Internal.chainInfo>> = ref(None)

Indexer.Gravatar.EmptyEvent.handler(async ({context}) => {
  // This handler tests that chain state is accessible in the context
  // Chain will have isLive: false during sync and isLive: true during live indexing
  lastEmptyEventChain := Some(context.chain)

  // Log chain state for verification
  let status = context.chain.isLive ? "ready (live)" : "syncing (historical)"
  context.log.debug(`Chain ${context.chain.id->Belt.Int.toString} status: ${status}`)
})
