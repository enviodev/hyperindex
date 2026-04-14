@get external getNumber: Internal.eventBlock => int = "height"
@get external getTimestamp: Internal.eventBlock => int = "time"
@get external getId: Internal.eventBlock => string = "id"

let cleanUpRawEventFieldsInPlace: Js.Json.t => unit = %raw(`fields => {
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
  extractOnBlockNumberFilter: filter =>
    filter
    ->(Utils.magic: unknown => {"block": option<{"height": option<unknown>}>})
    ->(r => r["block"])
    ->Belt.Option.flatMap(b => b["height"]),
}
