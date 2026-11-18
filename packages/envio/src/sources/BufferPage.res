// What a source returns: raw rows per table, the blocks among them holding an
// event a contractRegister runs on, and what validating the response needs.
type t

// The chain buffer pages merge into, as the source bindings name it: those
// take the buffer to read what it already holds.
type buffer

// A block a source saw: its hash, and maybe its time.
type observedBlock = {blockNumber: int, blockHash?: string, blockTimestamp?: int}

// An item built in JS (simulate and mock sources), with its registration
// replaced by the registration's index.
type decodedEvent = {
  kind: int,
  blockNumber: int,
  logIndex: int,
  orderPath?: array<int>,
  registrationIndex: int,
  item: dict<unknown>,
  // Its transaction's key in the buffer, when the item doesn't carry the
  // transaction itself.
  transactionIndex?: int,
  blockFromStore: bool,
}

@send external emptyRaw: (Core.pageCtor, string) => t = "empty"
@send
external fromJsRaw: (
  Core.pageCtor,
  string,
  array<observedBlock>,
  Null.t<array<decodedEvent>>,
) => t = "fromJs"

let empty = (~ecosystem: Ecosystem.name) => Core.getAddon().page->emptyRaw((ecosystem :> string))

let fromBlocks = (blocks, ~ecosystem: Ecosystem.name) =>
  Core.getAddon().page->fromJsRaw((ecosystem :> string), blocks, Null.Null)

// A page of items built in JS. Each is stored as plain data without its
// registration, which a build puts back by index.
let fromItems = (items: array<Internal.item>, ~blocks, ~ecosystem: Ecosystem.name) =>
  Core.getAddon().page->fromJsRaw(
    (ecosystem :> string),
    blocks,
    Null.Value(
      items->Array.map(item => {
        let data = item->(Utils.magic: Internal.item => dict<unknown>)->Dict.copy
        switch item {
        | Event({
            onEventRegistration,
            blockNumber,
            logIndex,
            ?orderPath,
            transactionIndex,
            payload,
          }) =>
          data->Dict.delete("onEventRegistration")
          {
            kind: 0,
            blockNumber,
            logIndex,
            ?orderPath,
            registrationIndex: onEventRegistration.index,
            item: data,
            transactionIndex: ?switch payload->Internal.getPayloadTransaction->Nullable.toOption {
            | Some(_) => None
            | None => Some(transactionIndex)
            },
            blockFromStore: payload->Internal.getPayloadBlock->Nullable.toOption->Option.isNone,
          }
        | Block({onBlockRegistration, blockNumber, ?block, ?skipped}) =>
          data->Dict.delete("onBlockRegistration")
          {
            kind: 1,
            blockNumber,
            logIndex: 0,
            registrationIndex: onBlockRegistration.index,
            item: data,
            blockFromStore: block->Option.isNone && skipped !== Some(true),
          }
        }
      }),
    ),
  )

// Event rows: logs, instructions or receipts, and decoded events.
@send external rowCount: t => int = "rowCount"
@send external firstRowBlockNumber: t => Null.t<int> = "firstRowBlockNumber"

// Moves another page's rows into this one.
@send external append: (t, t) => unit = "append"

// The lowest block whose received hash differs from the stored one.
type hashMismatch = {blockNumber: int, storedHash: string, receivedHash: string}

// A block this response reported two hashes for. Such a response is
// retried rather than taken for a reorg.
@send external responseConflict: t => Null.t<hashMismatch> = "responseConflict"

// The requested blocks the response holds no hash for. On SVM a slot the
// cursor covered without a block counts as held: the chain skipped it.
@send external missingHashes: (t, array<int>) => array<int> = "missingHashes"

type svmTxInput = {
  slot: int,
  transactionIndex: int,
  signature?: string,
  allSignatures?: array<string>,
  feePayer?: string,
  success?: bool,
  err?: string,
  fee?: bigint,
  computeUnitsConsumed?: bigint,
  accountKeys?: array<string>,
  recentBlockhash?: string,
  version?: string,
}

type svmActivityInput = {
  slot: int,
  transactionIndex: int,
  account: string,
  accountIndex?: int,
  isSigner?: bool,
  isWritable?: bool,
  preBalance?: bigint,
  postBalance?: bigint,
  mint?: string,
  owner?: string,
  decimals?: int,
  preAmount?: bigint,
  postAmount?: bigint,
}

@send
external fromSvmJsRaw: (
  Core.pageCtor,
  array<svmTxInput>,
  array<svmActivityInput>,
  array<observedBlock>,
) => t = "fromSvmJs"

// A page of simulated SVM transactions, their account activity and slots,
// which simulated instructions read from the buffer as fetched ones do.
let fromSvmJs = (transactions, activities, blocks) =>
  Core.getAddon().page->fromSvmJsRaw(transactions, activities, blocks)
