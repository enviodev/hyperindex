@genType
let mockRawEventRow: TablesStatic.RawEvents.t = {
  chainId: 1,
  eventId: 1234567890->Belt.Int.toString,
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: S.serializeOrRaiseWith(
    {
      Types.Transaction.transactionIndex: 20,
      hash: "0x1234567890abcdef",
    },
    Types.Transaction.schema,
  ),
  srcAddress: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  blockHash: "0x9876543210fedcba9876543210fedcba987654321",
  blockTimestamp: 1620720000,
  blockFields: S.serializeOrRaiseWith(({}: Types.Block.selectableFields), Types.Block.schema),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}
