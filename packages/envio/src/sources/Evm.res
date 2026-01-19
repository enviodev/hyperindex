@get external getNumber: Internal.eventBlock => int = "number"
@get external getTimestamp: Internal.eventBlock => int = "timestamp"
@get external getId: Internal.eventBlock => string = "hash"

let cleanUpRawEventFieldsInPlace: Js.Json.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.number
    delete fields.timestamp
  }`)

let ecosystem: Ecosystem.t = {
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
  getNumber,
  getTimestamp,
  getId,
  cleanUpRawEventFieldsInPlace,
}



