// Fuel's concrete item payload. Erased to `Internal.eventPayload` on the item
// and recovered here via `toPayload`. The block lives raw in the per-chain
// store and is written onto the payload at batch prep (like HyperSync EVM);
// simulate builds it inline.
type payload = {
  contractName: string,
  eventName: string,
  params: Internal.eventParams,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: Internal.eventTransaction,
  block?: Internal.eventBlock,
}
external fromPayload: payload => Internal.eventPayload = "%identity"
external toPayload: Internal.eventPayload => payload = "%identity"

// Ordered block field names. The index of each is the field code shared with
// the Rust store (`FuelBlockField`) — keep this order in sync.
let blockFields = ["id", "height", "time"]

// Fuel has no per-event block field selection: every event materialises the
// full (height, time, id) trio, matching what the source always queries.
let fullBlockFieldMask = BlockStore.makeMaskFn(blockFields)(Utils.Set.fromArray(blockFields))

let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.id
    delete fields.height
    delete fields.time
  }`)

let make = (~logger: Pino.t): Ecosystem.t => {
  name: Fuel,
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "id",
  cleanUpRawEventFieldsInPlace,
  onBlockMethodName: "onBlock",
  // Fuel filter shape: `{block: {height: {_gte?, _lte?, _every?}}}`.
  // Inner range chunk parsed by `blockRangeSchema` in `Main.res`.
  onBlockFilterSchema: S.object(s =>
    s.field("block", S.option(S.object(s2 => s2.field("height", S.unknown))))
  ),
  // Fuel event filter shape: `{block: {height: {_gte?}}, params?, ...}`.
  // Analogous to EVM, but keyed by `block.height` instead of
  // `block.number`. See `Evm.res` for the rationale on the two-stage
  // parse and the `_lte`/`_every` rejection.
  // `S.strict` on the inner object rejects unknown `block` fields — including
  // `block.number`, which is EVM-only; Fuel filters by `block.height`.
  onEventBlockFilterSchema: S.object(s =>
    s.field("block", S.option(S.object(s2 => s2.field("height", S.unknown))->S.strict))
  ),
  logger,
  toEvent: eventItem => eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event),
  toEventLogger: eventItem =>
    Logging.createChildFrom(
      ~logger,
      ~params={
        "contract": eventItem.onEventRegistration.eventConfig.contractName,
        "event": eventItem.onEventRegistration.eventConfig.name,
        "chainId": eventItem.chain->ChainMap.Chain.toChainId,
        "block": eventItem.blockNumber,
        "logIndex": eventItem.logIndex,
        "address": (eventItem.payload->toPayload).srcAddress,
      },
    ),
  toRawEvent: eventItem => {
    let payload = eventItem.payload->toPayload
    // Store-backed payloads get `block` written at batch prep and simulate
    // carries it from the start, so it's present by the time a raw event is built.
    let header = switch payload.block {
    | Some(block) => block->(Utils.magic: Internal.eventBlock => {"id": string, "time": int})
    | None =>
      JsError.throwWithMessage("Unexpected case: The event block is missing for a raw event")
    }
    eventItem->RawEvent.make(
      ~block=payload.block,
      ~transaction=payload.transaction,
      ~params=payload.params,
      ~srcAddress=payload.srcAddress,
      ~blockHash=header["id"],
      ~blockTimestamp=header["time"],
      ~cleanUpRawEventFieldsInPlace,
    )
  },
}
