@get external getNumber: Internal.eventBlock => int = "height"
@get external getTimestamp: Internal.eventBlock => int = "time"
@get external getId: Internal.eventBlock => string = "id"

let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.id
    delete fields.height
    delete fields.time
  }`)

let ecosystem: Ecosystem.t = {
  name: Fuel,
  blockFields: ["id", "height", "time"],
  transactionFields: ["id"],
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "id",
  getNumber,
  getTimestamp,
  getId,
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
}
