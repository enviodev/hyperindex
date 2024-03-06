open Types

let encodeName_string: eventName => string = eventName_encode(_)->Obj.magic
@genType
let eventNames = {
  "NftFactory_SimpleNftCreated": NftFactory_SimpleNftCreated->encodeName_string,
}

let event_type: string = Types.eventName_encode(NftFactory_SimpleNftCreated)->Obj.magic

@genType
let mockRawEventRow = {
  "chain_id": 1,
  "event_id": 1234567890,
  "block_number": 1000,
  "log_index": 10,
  "transaction_index": 20,
  "transaction_hash": "0x1234567890abcdef",
  "src_address": "0x0123456789abcdef0123456789abcdef0123456",
  "block_hash": "0x9876543210fedcba9876543210fedcba987654321",
  "event_type": event_type,
  "block_timestamp": 1620720000,
  "params": {
    "foo": "bar",
    "baz": 42,
  },
}
