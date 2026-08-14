// Packs blockNumber and logIndex into one number: 32 bits and 16 bits
// respectively. EVM only — it is the `raw_events.event_id` primary value, and
// no other ecosystem writes that table.
let packEventIndex = (~blockNumber, ~logIndex) => {
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt
  let blockNumber = BigInt.shiftLeft(blockNumber, 16->BigInt.fromInt)

  blockNumber->BigInt.bitwiseOr(logIndex)
}
