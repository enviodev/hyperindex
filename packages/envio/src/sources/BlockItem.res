// A block handler run on one block of a response, as every native client
// routes it (`block_selection.rs`). The block itself is in the response's
// block store, to be materialised at batch prep.
type t = {
  blockNumber: int,
  onBlockRegistrationIndex: int,
}

// A block handler selecting fields, as a native client is built with it.
type registrationInput = {
  index: int,
  startBlock: int,
  endBlock: option<int>,
  interval: int,
  blockFieldMask: float,
}

// The chain's block handlers a source fetches blocks for: those selecting
// fields, the rest being generated without one.
let toRegistrationInputs = (onBlockRegistrations: array<Internal.onBlockRegistration>) =>
  onBlockRegistrations->Array.filterMap(({index, startBlock, endBlock, interval, blockFieldMask}) =>
    blockFieldMask->Option.map(blockFieldMask => {
      index,
      // Resolved to the chain's start block by `ChainState` when absent.
      startBlock: startBlock->Option.getOr(0),
      endBlock,
      interval,
      blockFieldMask,
    })
  )

let toIndexes = (onBlockRegistrations: array<Internal.onBlockRegistration>) =>
  onBlockRegistrations->Array.map(reg => reg.index)

let toInternalItems = (
  items: array<t>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>,
): array<Internal.item> =>
  items->Array.map(({blockNumber, onBlockRegistrationIndex}) => Internal.Block({
    onBlockRegistration: onBlockRegistrations->Array.getUnsafe(onBlockRegistrationIndex),
    blockNumber,
  }))
