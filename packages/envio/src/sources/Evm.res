// EVM's concrete item payload. Erased to `Internal.eventPayload` on the item
// and recovered here via `toPayload`. HyperSync omits `transaction` (it lives
// raw in the per-chain store and is written onto the payload at batch prep);
// RPC/simulate build it inline.
type payload = {
  contractName: string,
  eventName: string,
  params: Internal.eventParams,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction?: Internal.eventTransaction,
  // HyperSync omits `block` (it lives raw in the per-chain store and is written
  // onto the payload at batch prep); RPC/simulate build it inline.
  block?: Internal.eventBlock,
}
external fromPayload: payload => Internal.eventPayload = "%identity"
external toPayload: Internal.eventPayload => payload = "%identity"

// Ordered transaction field names, the field codes shared with the Rust store
// (`EvmTxField`). Derived from the typed field list so the two can't drift;
// `Internal.allEvmTransactionFields` is pinned to the Rust ordinal order by a test.
let transactionFields =
  Internal.allEvmTransactionFields->(
    Utils.magic: array<Internal.evmTransactionField> => array<string>
  )

// One event's selected transaction fields → store selection bitmask. Computed
// per event at config build and cached on the event config.
let eventTransactionFieldMask = TransactionStore.makeMaskFn(transactionFields)

// Ordered block field names. The index of each is the field code shared with the
// Rust store (`EvmBlockField`) — keep this order in sync.
let blockFields = [
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
]

// One event's selected block fields → store selection bitmask. Computed per
// event at config build and cached on the event config.
let eventBlockFieldMask = BlockStore.makeMaskFn(blockFields)

let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.number
    delete fields.timestamp
  }`)

let make = (~logger: Pino.t): Ecosystem.t => {
  name: Evm,
  blockNumberName: "number",
  blockTimestampName: "timestamp",
  blockHashName: "hash",
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
  logger,
  // The payload carries `transaction` by batch prep (HyperSync) or inline
  // (RPC/simulate), so the event is the payload as-is.
  toEvent: eventItem => eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event),
  toEventLogger: eventItem =>
    Logging.createChildFrom(
      ~logger,
      ~params={
        "contract": eventItem.onEventRegistration.eventConfig.contractName,
        "event": eventItem.onEventRegistration.eventConfig.name,
        "chainId": eventItem.chain->ChainMap.Chain.toChainId,
        "block": eventItem.blockNumber,
        "logIndex": eventItem.logIndex,
        "address": (eventItem.payload->toPayload).srcAddress,
      },
    ),
  toRawEvent: eventItem => {
    let payload = eventItem.payload->toPayload
    let eventConfig =
      eventItem.onEventRegistration.eventConfig->(
        Utils.magic: Internal.eventConfig => Internal.evmEventConfig
      )
    // Store-backed payloads get `block` written at batch prep and inline
    // sources carry it from the start, with hash/timestamp always selected —
    // so both are present by the time a raw event is built.
    let header = switch payload.block {
    | Some(block) => block->(Utils.magic: Internal.eventBlock => {"hash": string, "timestamp": int})
    | None =>
      JsError.throwWithMessage("Unexpected case: The event block is missing for a raw event")
    }
    eventItem->RawEvent.make(
      ~block=payload.block,
      ~transaction=payload.transaction,
      // The decoder emits `{}` for zero-parameter events, which the params
      // schema rejects; pass unit so it serializes to the "null" sentinel.
      ~params=eventConfig.paramsMetadata->Array.length == 0
        ? ()->(Utils.magic: unit => Internal.eventParams)
        : payload.params,
      ~srcAddress=payload.srcAddress,
      ~blockHash=header["hash"],
      ~blockTimestamp=header["timestamp"],
      ~cleanUpRawEventFieldsInPlace,
    )
  },
}
