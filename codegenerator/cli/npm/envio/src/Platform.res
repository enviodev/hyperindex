type name = | @as("evm") Evm | @as("fuel") Fuel

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

module Evm = {
  @get external getNumber: Internal.eventBlock => int = "number"
  @get external getTimestamp: Internal.eventBlock => int = "timestamp"
  @get external getId: Internal.eventBlock => string = "hash"

  let cleanUpRawEventFieldsInPlace: Js.Json.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.number
    delete fields.timestamp
  }`)
}

let evm: t = {
  name: Evm,
  blockFields: [
    "number",
    "timestamp",
    "hash",
    "parentHash",
    "nonce",
    "sha3Uncles",
    "logsBloom",
    "transactionsRoot",
    "stateRoot",
    "receiptsRoot",
    "miner",
    "difficulty",
    "totalDifficulty",
    "extraData",
    "size",
    "gasLimit",
    "gasUsed",
    "uncles",
    "baseFeePerGas",
    "blobGasUsed",
    "excessBlobGas",
    "parentBeaconBlockRoot",
    "withdrawalsRoot",
    "l1BlockNumber",
    "sendCount",
    "sendRoot",
    "mixHash",
  ],
  transactionFields: [
    "transactionIndex",
    "hash",
    "from",
    "to",
    "gas",
    "gasPrice",
    "maxPriorityFeePerGas",
    "maxFeePerGas",
    "cumulativeGasUsed",
    "effectiveGasPrice",
    "gasUsed",
    "input",
    "nonce",
    "value",
    "v",
    "r",
    "s",
    "contractAddress",
    "logsBloom",
    "root",
    "status",
    "yParity",
    "chainId",
    "maxFeePerBlobGas",
    "blobVersionedHashes",
    "type",
    "l1Fee",
    "l1GasPrice",
    "l1GasUsed",
    "l1FeeScalar",
    "gasUsedForL1",
    "accessList",
    "authorizationList",
  ],
  blockNumberName: "number",
  blockTimestampName: "timestamp",
  blockHashName: "hash",
  getNumber: Evm.getNumber,
  getTimestamp: Evm.getTimestamp,
  getId: Evm.getId,
  cleanUpRawEventFieldsInPlace: Evm.cleanUpRawEventFieldsInPlace,
}

module Fuel = {
  @get external getNumber: Internal.eventBlock => int = "height"
  @get external getTimestamp: Internal.eventBlock => int = "time"
  @get external getId: Internal.eventBlock => string = "id"

  let cleanUpRawEventFieldsInPlace: Js.Json.t => unit = %raw(`fields => {
    delete fields.id
    delete fields.height
    delete fields.time
  }`)
}

let fuel: t = {
  name: Fuel,
  blockFields: ["id", "height", "time"],
  transactionFields: ["id"],
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "id",
  getNumber: Fuel.getNumber,
  getTimestamp: Fuel.getTimestamp,
  getId: Fuel.getId,
  cleanUpRawEventFieldsInPlace: Fuel.cleanUpRawEventFieldsInPlace,
}

let fromName = (name: name): t => {
  switch name {
  | Evm => evm
  | Fuel => fuel
  }
}

// Create a block event object for block handlers based on platform
let makeBlockEvent = (~blockNumber: int, platform: t): Internal.blockEvent => {
  let blockEvent = Js.Dict.empty()
  blockEvent->Js.Dict.set(platform.blockNumberName, blockNumber->Utils.magic)
  blockEvent->Utils.magic
}
