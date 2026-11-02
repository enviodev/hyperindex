// The block itself is in the response's block store, materialised at batch
// prep.
type t = {
  blockNumber: int,
  onBlockRegistrationIndex: int,
  skipped: bool,
}

let isFetched = (reg: Internal.onBlockRegistration) => reg.blockFieldMask->Option.isSome

// Mirrors `Registration::runs_on` in `block_selection.rs`.
let runsOn = (
  {startBlock, endBlock, interval}: Internal.onBlockRegistration,
  ~blockNumber,
  ~chainStartBlock,
) => {
  let startBlock = startBlock->Option.getOr(chainStartBlock)
  blockNumber >= startBlock &&
  endBlock->Option.mapOr(true, endBlock => blockNumber <= endBlock) &&
  Pervasives.mod(blockNumber - startBlock, interval) === 0
}

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

let toInternalItems = (
  items: array<t>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>,
): array<Internal.item> =>
  items->Array.map(({blockNumber, onBlockRegistrationIndex, skipped}) => Internal.Block({
    onBlockRegistration: onBlockRegistrations->Array.getUnsafe(onBlockRegistrationIndex),
    blockNumber,
    skipped: ?(skipped ? Some(true) : None),
  }))
