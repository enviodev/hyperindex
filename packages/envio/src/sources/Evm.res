@get external getNumber: Internal.eventBlock => int = "number"
@get external getTimestamp: Internal.eventBlock => int = "timestamp"
@get external getId: Internal.eventBlock => string = "hash"

let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
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
  onBlockMethodName: "onBlock",
  // EVM filter shape: `{block: {number: {_gte?, _lte?, _every?}}}`.
  // The inner range chunk is returned as raw `S.unknown` and parsed a
  // second time in `Main.res` by the shared `blockRangeSchema`.
  onBlockFilterSchema: S.object(s =>
    s.field("block", S.option(S.object(s2 => s2.field("number", S.unknown))))
  ),
  // EVM event filter shape: `{block: {number: {_gte?}}, params?, ...}`.
  // Only the `block.number` wrapper is unwrapped here; sibling fields
  // like `params` are left for `LogSelection` to consume. The inner
  // range chunk is validated by `eventBlockRangeSchema` in
  // `LogSelection.res` which rejects `_lte`/`_every` (use `onBlock` for
  // stride- and endBlock-based block handlers).
  onEventBlockFilterSchema: S.object(s =>
    s.field("block", S.option(S.object(s2 => s2.field("number", S.unknown))))
  ),
}
