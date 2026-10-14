// One `context.sidecar.<fn>(input)` call, as the batch carries it until the
// commit. `checkpointId` stays internal: it groups calls by block for the test
// indexer and is not part of the wire format.
type t = {
  id: string,
  fn: string,
  chainId: ChainId.t,
  blockNumber: int,
  blockTimestamp: option<int>,
  checkpointId: Internal.checkpointId,
  // The contract schema's JSON form, so bigint and BigDecimal are strings.
  input: JSON.t,
}
