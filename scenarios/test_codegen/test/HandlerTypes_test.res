// Type-level tests for the new onEvent / contractRegister API.
// These tests pass if the file compiles. ReScript's type system IS the assertion.

open Vitest

// All let bindings below are wrapped in a function so they don't actually run —
// we only care that they type-check at compile time.
// The trivial test case at the end is what vitest picks up.

// 1. Per-contract eventIdentity GADT — string-typed at runtime via @as
let _gravatarNewGravatar: Indexer.Gravatar.eventIdentity<_, _, _> = NewGravatar
let _nftFactorySimpleNft: Indexer.NftFactory.eventIdentity<_, _, _> = SimpleNftCreated
let _simpleNftTransfer: Indexer.SimpleNft.eventIdentity<_, _, _> = Transfer
let _noopEmpty: Indexer.Noop.eventIdentity<_, _, _> = EmptyEvent

// 2. Top-level eventIdentity GADT — wraps per-contract identity with @tag("contract")
let _topNftFactory: Indexer.eventIdentity<_, _, _> = NftFactory(SimpleNftCreated)
let _topGravatar: Indexer.eventIdentity<_, _, _> = Gravatar(NewGravatar)
let _topSimpleNft: Indexer.eventIdentity<_, _, _> = SimpleNft(Transfer)

// 3. onEventOptions wraps the GADT, with optional wildcard and `where`.
let _basicConfig: Indexer.onEventOptions<Indexer.eventIdentity<_, _, _>, _> = {
  event: NftFactory(SimpleNftCreated),
}
let _wildcardConfig: Indexer.onEventOptions<Indexer.eventIdentity<_, _, _>, _> = {
  event: Gravatar(NewGravatar),
  wildcard: true,
}
// `where` carries the per-event filter value. The `'where` type parameter on
// onEventOptions unifies with the GADT constructor's third type argument,
// so passing `event: EventFiltersTest(Transfer)` pins `'where` to
// `EventFiltersTest.Transfer.onEventWhere`. In ReScript `where` is *always*
// a callback — OR semantics are expressed via an array on `params`, not at
// the top level of `where`. `SingleOrMultiple.t` is opaque — construct via
// `single` / `multiple`. The inner `whereParams` record needs an explicit
// annotation because `single`'s generic type parameter doesn't propagate
// inference through the opaque type.
module TransferEvent = Indexer.EventFiltersTest.Transfer
let _staticFilterConfig: Indexer.onEventOptions<
  Indexer.eventIdentity<_, _, _>,
  TransferEvent.onEventWhere,
> = {
  event: EventFiltersTest(Transfer),
  where: _ => {
    let p: TransferEvent.whereParams = {
      from: Indexer.SingleOrMultiple.single(
        "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
      ),
    }
    Filter({params: Indexer.SingleOrMultiple.single(p)})
  },
}
// Wildcard + multi-condition OR filter — two AND-conjunctions on `params`,
// expressing `(to=A) OR (to=B)`.
let _wildcardWithFilterConfig: Indexer.onEventOptions<
  Indexer.eventIdentity<_, _, _>,
  TransferEvent.onEventWhere,
> = {
  event: EventFiltersTest(Transfer),
  wildcard: true,
  where: _ => {
    let conditions: array<TransferEvent.whereParams> = [
      {
        to: Indexer.SingleOrMultiple.single(
          "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
        ),
      },
      {
        to: Indexer.SingleOrMultiple.single(
          "0x0000000000000000000000000000000000000001"->Address.unsafeFromString,
        ),
      },
    ]
    Filter({params: Indexer.SingleOrMultiple.multiple(conditions)})
  },
}

// 4. handlerContext (onEvent context) has expected fields
let _checkHandlerContext = (ctx: Indexer.handlerContext) => {
  let _: bool = ctx.isPreload
  let chainInfo: Internal.chainInfo = ctx.chain
  let _: int = chainInfo.id
  let _: bool = chainInfo.isLive
  let _: Envio.logger = ctx.log
}

// 5. contractRegisterContext has chain.ContractName.add() registration.
// Note: chain does NOT expose isLive — contract registration runs during sync
// so the "live" distinction isn't meaningful and the field was dropped.
let _checkContractRegisterContext = (ctx: Indexer.contractRegisterContext) => {
  let chain: Indexer.contractRegisterChain = ctx.chain
  let _: Indexer.chainId = chain.id
  let _: Envio.logger = ctx.log
  // chain.ContractName.add(address) is available for each configured contract
  let zero = "0x0000000000000000000000000000000000000000"->Address.unsafeFromString
  chain.\"NftFactory".add(zero)
  chain.\"SimpleNft".add(zero)
  chain.\"Gravatar".add(zero)
  chain.\"EventFiltersTest".add(zero)
  chain.\"Noop".add(zero)
  chain.\"TestEvents".add(zero)
}

// 6. indexer.onEvent compiles with proper GADT identity and handler
let _registerOnEvent = () => {
  Indexer.indexer.onEvent(
    {event: NftFactory(SimpleNftCreated)},
    async ({event, context}) => {
      // event params are typed for the specific contract+event
      let _: Address.t = event.params.contractAddress
      let _: bool = context.isPreload
    },
  )
}

// 7. indexer.contractRegister compiles and exposes context.chain.ContractName.add()
let _registerContractRegister = () => {
  Indexer.indexer.contractRegister(
    {event: NftFactory(SimpleNftCreated)},
    async ({event, context}) => {
      context.chain.\"SimpleNft".add(event.params.contractAddress)
    },
  )
}

// 8. wildcard option is supported
let _registerWildcard = () => {
  Indexer.indexer.onEvent(
    {event: SimpleNft(Transfer), wildcard: true},
    async ({event: _, context: _}) => (),
  )
}

// 9. `where` callback returning a single filter condition — typed against
// the event's per-event `onEventWhere` function type.
let _registerWithStaticFilter = () => {
  Indexer.indexer.onEvent(
    {
      event: EventFiltersTest(Transfer),
      where: _ => {
        let p: TransferEvent.whereParams = {
          from: Indexer.SingleOrMultiple.single(
            "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          ),
        }
        Filter({params: Indexer.SingleOrMultiple.single(p)})
      },
    },
    async ({event: _, context: _}) => (),
  )
}

// 10. `where` combined with wildcard — the filter callback survives alongside
// wildcard: true, and the `'where` generic is pinned by the GADT identity.
let _registerWildcardWithFilter = () => {
  Indexer.indexer.onEvent(
    {
      event: EventFiltersTest(Transfer),
      wildcard: true,
      where: _ => {
        let p: TransferEvent.whereParams = {
          to: Indexer.SingleOrMultiple.single(
            "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          ),
        }
        Filter({params: Indexer.SingleOrMultiple.single(p)})
      },
    },
    async ({event: _, context: _}) => (),
  )
}

// 11. Dynamic callback that reads chain id and the event's own contract addresses.
let _registerDynamicFilter = () => {
  Indexer.indexer.onEvent(
    {
      event: EventFiltersTest(Transfer),
      wildcard: true,
      where: ({chain}) => {
        let _ = chain.id
        let _ = chain.\"EventFiltersTest".addresses
        let p: TransferEvent.whereParams = {
          from: Indexer.SingleOrMultiple.single(
            "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
          ),
        }
        Filter({params: Indexer.SingleOrMultiple.single(p)})
      },
    },
    async ({event: _, context: _}) => (),
  )
}

// 12. Callback returning KeepAll (true) — short-circuit keep all events.
let _registerDynamicKeepAll = () => {
  Indexer.indexer.onEvent(
    {
      event: EventFiltersTest(Transfer),
      wildcard: true,
      where: _ => KeepAll,
    },
    async ({event: _, context: _}) => (),
  )
}

// Trivial vitest case so the runner picks up this file alongside other ReScript tests.
describe("HandlerTypes", () => {
  it("compiles", t => {
    t.expect(true).toBe(true)
  })
})
