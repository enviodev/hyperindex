let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.id
    delete fields.height
    delete fields.time
  }`)

let make = (~logger: Pino.t): Ecosystem.t => {
  name: Fuel,
  blockFields: ["id", "height", "time"],
  transactionFields: ["id"],
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
  toEvent: eventItem => eventItem.payload->Internal.payloadToEvent,
  toEventLogger: eventItem =>
    Logging.createChildFrom(
      ~logger,
      ~params={
        "contract": eventItem.eventConfig.contractName,
        "event": eventItem.eventConfig.name,
        "chainId": eventItem.chain->ChainMap.Chain.toChainId,
        "block": eventItem.blockNumber,
        "logIndex": eventItem.logIndex,
        "address": (eventItem.payload->Internal.payloadToGenericEvent).srcAddress,
      },
    ),
  toRawEvent: eventItem => eventItem->RawEvent.make(~cleanUpRawEventFieldsInPlace),
}
