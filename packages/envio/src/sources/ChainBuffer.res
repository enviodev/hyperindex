// Binding to the Rust `ChainBuffer` napi class: one chain's fetched rows,
// from the moment a source returns them until the chain removes them. It keeps
// no processing state; the chain says which range a build reads and when
// processed rows go.
type t = BufferPage.buffer

module Page = BufferPage

// The registrations with a contractRegister, by index.
let contractRegisterIndexesOf = (onEventRegistrations: array<Internal.onEventRegistration>) =>
  onEventRegistrations->Array.filterMap(registration =>
    switch registration {
    | {contractRegister: Some(_), index} => Some(index)
    | _ => None
    }
  )

type config = {
  ecosystem: string,
  shouldChecksum: bool,
  evmRegistrations?: array<HyperSyncClient.Registration.input>,
  svmRegistrations?: array<SvmHyperSyncClient.Registration.program>,
  fuelRegistrations?: array<FuelHyperSyncClient.Registration.input>,
  contractRegisterIndexes: array<int>,
  blockHandlers: array<BlockItem.blockHandlerInput>,
  // By event registration index.
  transactionMasks: array<float>,
  eventBlockMasks: array<float>,
}

@send external make: (Core.chainBufferCtor, config, AddressStore.t) => t = "make"

type mergedPage = {
  // The block whose received hash differs from the stored one. Unless the
  // merge only reports, nothing was merged.
  mismatch: option<Page.hashMismatch>,
  rowsKept: int,
  registeringBlockNumbers: array<int>,
}

// Compares the page's hashes at or above `reorgThreshold` with the stored
// ones and merges the page unless one differs; with `reportOnly` it merges
// either way. The page is left empty.
@send
external mergePage: (t, Page.t, ~reorgThreshold: int, ~reportOnly: bool) => mergedPage = "mergePage"

// The columns of one arena, as `Reading` builds its views from them.
type arenaShape = {
  names: array<string>,
  kinds: array<Reading.kind>,
  elementKinds: array<Null.t<Reading.kind>>,
  rows: int,
}

type paramsShape = {registrationIndex: int, shape: arenaShape}

// A build's transactions or blocks: an arena with a row each and a column per
// selected field, the nested fields beside it.
type fieldRows = {
  shape: arenaShape,
  accessList?: array<Nullable.t<unknown>>,
  authorizationList?: array<Nullable.t<unknown>>,
  accountActivities?: array<Nullable.t<unknown>>,
}

// Items built from the buffer: the arenas behind `handle` hold `items`, each
// registration's `params`, `fuel`, `svm`, `links`, then `transactions` and
// `blocks` when present.
type builtItems = {
  handle: int,
  items: arenaShape,
  params: array<paramsShape>,
  fuel: arenaShape,
  svm: arenaShape,
  links: arenaShape,
  transactions: option<fieldRows>,
  blocks: option<fieldRows>,
  tapes: array<unknown>,
  itemCount: int,
  rowsRead: int,
  // The last block the items cover whole.
  lastBlock: option<int>,
}

// Matches, decodes and joins blocks `[fromBlock, maxBlock]` off the JS
// thread, stopping at the first block boundary at or past `targetItems`.
@send
external buildHandlerItems: (
  t,
  ~fromBlock: int,
  ~maxBlock: int,
  ~targetItems: int,
) => promise<builtItems> = "buildHandlerItems"

// The same for exactly these blocks and only registrations with a
// contractRegister.
@send
external buildContractRegisterItems: (
  t,
  ~blockNumbers: array<int>,
  ~targetItems: int,
) => promise<builtItems> = "buildContractRegisterItems"

// Removes transactions and everything inside them: logs, instructions,
// receipts and decoded events. Returns the event rows removed.
@send
external removeTransactionDataInBlockRange: (t, ~fromBlock: int, ~toBlock: int) => int =
  "removeTransactionDataInBlockRange"

// Removes block rows, hashes included.
@send
external removeBlocksInBlockRange: (t, ~fromBlock: int, ~toBlock: int) => int =
  "removeBlocksInBlockRange"

@send
external countRowsInBlockRange: (t, ~fromBlock: int, ~toBlock: int) => int = "countRowsInBlockRange"

// Of the handlers `registrationIndexes` names, or of every handler.
@send
external countBlockHandlerRunsInBlockRange: (
  t,
  ~fromBlock: int,
  ~toBlock: int,
  ~registrationIndexes: array<int>=?,
) => float = "countBlockHandlerRunsInBlockRange"

// Rows and block handler runs of blocks `[fromBlock, toBlock]`: what a build
// of the range produces at most.
let countItemsInBlockRange = (buffer, ~fromBlock, ~toBlock) =>
  if toBlock < fromBlock {
    0
  } else {
    buffer->countRowsInBlockRange(~fromBlock, ~toBlock) +
      buffer->countBlockHandlerRunsInBlockRange(~fromBlock, ~toBlock)->Float.toInt
  }

// The block of the row `rowOffset` rows past the first one at or above
// `fromBlock`.
@send
external getBlockNumberOfRowAt: (t, ~fromBlock: int, ~rowOffset: int) => Null.t<int> =
  "getBlockNumberOfRowAt"

// Every stored event row.
@send external rowCount: t => int = "rowCount"

// The bytes the buffer's tables hold.
@send external heapBytes: t => float = "heapBytes"

@send external getBlockHash: (t, int) => Null.t<string> = "getBlockHash"

type hashedBlocks = {blockNumbers: array<int>, hashes: array<string>}

// Every stored hash of blocks `[fromBlock, belowBlock)`, ascending.
@send
external getBlockHashes: (t, ~fromBlock: int, ~belowBlock: int) => hashedBlocks = "getBlockHashes"

// The highest of `blockNumbers`, taken ascending, up to which the page's
// hashes all match the stored ones.
@send
external findLatestBlockWithMatchingHash: (t, Page.t, array<int>) => Null.t<int> =
  "findLatestBlockWithMatchingHash"

// The time of a stored block. With `allowSkippedSlot` an SVM slot that
// produced no block reads the last slot below it that did: what chain time is
// at a skipped slot. Only set it where the query covered every slot in its
// range.
@send
external getBlockTimestamp: (t, int, ~allowSkippedSlot: bool) => Null.t<int> = "getBlockTimestamp"

@send external lendRowsRaw: (Core.chainBufferCtor, int) => array<ArrayBuffer.t> = "lendRows"
@send
external releaseRowsRaw: (Core.chainBufferCtor, int, array<ArrayBuffer.t>) => unit = "releaseRows"

// Reads the arenas Rust holds under `handle` with `f`, then hands their
// buffers back, whether or not `f` throws. Nothing may keep a view into them.
let readHandle = (handle, f: array<ArrayBuffer.t> => 'a): 'a => {
  let ctor = Core.getAddon().chainBuffer
  let buffers = ctor->lendRowsRaw(handle)
  let result = try f(buffers) catch {
  | exn =>
    ctor->releaseRowsRaw(handle, buffers)
    throw(exn)
  }
  ctor->releaseRowsRaw(handle, buffers)
  result
}

// A chain's buffer, from the registrations it matches and decodes against
// and the address store it reads.
let makeForChain = (
  ~ecosystem: Ecosystem.name,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>,
  ~shouldChecksum,
  ~addressStore,
) =>
  Core.getAddon().chainBuffer->make(
    {
      ecosystem: (ecosystem :> string),
      shouldChecksum,
      evmRegistrations: ?switch ecosystem {
      | Evm =>
        Some(
          onEventRegistrations
          ->(Utils.magic: array<Internal.onEventRegistration> => array<
            Internal.evmOnEventRegistration,
          >)
          ->HyperSyncClient.Registration.fromOnEventRegistrations,
        )
      | Svm | Fuel => None
      },
      svmRegistrations: ?switch ecosystem {
      | Svm =>
        Some(
          onEventRegistrations
          ->(Utils.magic: array<Internal.onEventRegistration> => array<
            Internal.svmOnEventRegistration,
          >)
          ->SvmHyperSyncClient.Registration.fromOnEventRegistrations,
        )
      | Evm | Fuel => None
      },
      fuelRegistrations: ?switch ecosystem {
      | Fuel =>
        Some(onEventRegistrations->FuelHyperSyncClient.Registration.fromOnEventRegistrations)
      | Evm | Svm => None
      },
      contractRegisterIndexes: onEventRegistrations->contractRegisterIndexesOf,
      blockHandlers: onBlockRegistrations->BlockItem.toBlockHandlerInputs,
      transactionMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.transactionMask
      ),
      eventBlockMasks: onEventRegistrations->Array.map(registration =>
        registration.fieldSelection.blockMask
      ),
    },
    addressStore,
  )
