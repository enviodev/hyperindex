type name = | @as("evm") Evm | @as("fuel") Fuel | @as("svm") Svm

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
  cleanUpRawEventFieldsInPlace: JSON.t => unit,
}

let makeOnBlockArgs = (~blockNumber: int, ~ecosystem: t, ~context): Internal.onBlockArgs => {
  switch ecosystem.name {
  | Svm => {slot: blockNumber, context}
  | _ => {
      let blockEvent = Dict.make()
      blockEvent->Dict.set(ecosystem.blockNumberName, blockNumber->Utils.magic)
      {block: blockEvent->Utils.magic, context}
    }
  }
}
