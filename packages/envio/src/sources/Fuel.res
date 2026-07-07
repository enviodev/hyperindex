// Fuel's concrete item payload. Erased to `Internal.eventPayload` on the item
// and recovered here via `toPayload`.
type payload = {
  contractName: string,
  eventName: string,
  params: Internal.eventParams,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: Internal.eventTransaction,
  block: Internal.eventBlock,
}
external fromPayload: payload => Internal.eventPayload = "%identity"
external toPayload: Internal.eventPayload => payload = "%identity"

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
  onEventBlockFilterSchema: S.object(s =>
    s.field("block", S.option(S.object(s2 => s2.field("height", S.unknown))))
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
    eventItem->RawEvent.make(
      ~block=payload.block,
      ~transaction=payload.transaction,
      ~params=payload.params,
      ~srcAddress=payload.srcAddress,
      ~cleanUpRawEventFieldsInPlace,
    )
  },
}
