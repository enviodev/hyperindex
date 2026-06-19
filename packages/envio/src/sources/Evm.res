// EVM's concrete item payload. Erased to `Internal.eventPayload` on the item
// and recovered here via `toPayload`. The transaction is not carried here — it
// lives in the per-chain transaction store and is resolved on demand.
type payload = {
  contractName: string,
  eventName: string,
  params: Internal.eventParams,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  block: Internal.eventBlock,
}
external fromPayload: payload => Internal.eventPayload = "%identity"
external toPayload: Internal.eventPayload => payload = "%identity"

// The event handed to handlers is the payload with a lazily-resolved
// `transaction` getter attached.
@set
external setEventTransaction: (Internal.event, Internal.eventTransaction) => unit = "transaction"
// True when the payload already carries an inline transaction (test mocks build
// payloads this way); production EVM sources don't, so the getter is attached.
let hasInlineTransaction: Internal.event => bool = %raw(`e => e.transaction !== undefined && e.transaction !== null`)
@get external inlineTransaction: Internal.event => Internal.eventTransaction = "transaction"
// The transaction store is stamped on the item by `ChainState` so `toRawEvent`
// (no store in its signature) can resolve transaction fields.
@get external itemTransactionStore: Internal.eventItem => TransactionStore.t = "_txStore"

// Ordered transaction field names. The index of each is the field code shared
// with the Rust store (`EvmTxField`) — keep this order in sync.
let transactionFields = [
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
]

let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.number
    delete fields.timestamp
  }`)

let make = (~logger: Pino.t): Ecosystem.t => {
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
  transactionFields,
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
  toEvent: (eventItem, ~transactionStore) => {
    let event = eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event)
    if !(event->hasInlineTransaction) {
      event->setEventTransaction(
        TransactionView.make(
          transactionFields,
          transactionStore,
          eventItem.blockNumber,
          eventItem.transactionId,
        ),
      )
    }
    event
  },
  toEventLogger: eventItem =>
    Logging.createChildFrom(
      ~logger,
      ~params={
        "contract": eventItem.eventConfig.contractName,
        "event": eventItem.eventConfig.name,
        "chainId": eventItem.chain->ChainMap.Chain.toChainId,
        "block": eventItem.blockNumber,
        "logIndex": eventItem.logIndex,
        "address": (eventItem.payload->toPayload).srcAddress,
      },
    ),
  toRawEvent: eventItem => {
    let payload = eventItem.payload->toPayload
    let event = eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event)
    let transaction = if event->hasInlineTransaction {
      event->inlineTransaction
    } else {
      TransactionView.toDict(
        transactionFields,
        eventItem->itemTransactionStore,
        eventItem.blockNumber,
        eventItem.transactionId,
      )->(Utils.magic: dict<unknown> => Internal.eventTransaction)
    }
    eventItem->RawEvent.make(
      ~block=payload.block,
      ~transaction,
      ~params=payload.params,
      ~srcAddress=payload.srcAddress,
      ~cleanUpRawEventFieldsInPlace,
    )
  },
}
