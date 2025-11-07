type name = | @as("evm") Evm | @as("fuel") Fuel

type t = {
  name: name,
  blockFields: array<string>,
  transactionFields: array<string>,
  blockNumberName: string,
  blockTimestampName: string,
  blockHashName: string,
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
    "kind",
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
}

let fuel: t = {
  name: Fuel,
  blockFields: ["id", "height", "time"],
  transactionFields: ["id"],
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "id",
}

let fromName = (name: name): t => {
  switch name {
  | Evm => evm
  | Fuel => fuel
  }
}
