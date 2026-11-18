// Packs blockNumber and logIndex into one number, 32 bits each. A log index can
// take all 32 of its bits: some providers number synthetic logs from the top of
// the range. EVM only — it is the `raw_events.event_id` primary value, and no
// other ecosystem writes that table.
let packEventIndex = (~blockNumber, ~logIndex) => {
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt
  let blockNumber = BigInt.shiftLeft(blockNumber, 32->BigInt.fromInt)

  blockNumber->BigInt.bitwiseOr(logIndex)
}
