type name = | @as("evm") Evm | @as("fuel") Fuel | @as("solana") Solana

type t = {
  name: name,
  blockFields: array<string>,
  transactionFields: array<string>,
  blockNumberName: string,
  blockTimestampName: string,
  blockHashName: string,
  getNumber: Internal.eventBlock => int,
  getTimestamp: Internal.eventBlock => int,
  getId: Internal.eventBlock => string,
  cleanUpRawEventFieldsInPlace: Js.Json.t => unit,
}

// Create a block event object for block handlers based on ecosystem
let makeBlockEvent = (~blockNumber: int, ecosystem: t): Internal.blockEvent => {
  let blockEvent = Js.Dict.empty()
  blockEvent->Js.Dict.set(ecosystem.blockNumberName, blockNumber->Utils.magic)
  blockEvent->Js.Dict.set("slot", blockNumber->Utils.magic) // FIXME:
  blockEvent->Utils.magic
}
