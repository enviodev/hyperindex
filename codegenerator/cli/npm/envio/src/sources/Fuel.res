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
}
