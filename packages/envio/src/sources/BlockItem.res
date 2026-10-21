// A block handler run on one block of a response, as every native client
// routes it (`block_selection.rs`). The block itself is in the response's
// block store, to be materialised at batch prep.
type t = {
  blockNumber: int,
  onBlockRegistrationIndex: int,
}

// A block handler selecting fields, as a native query carries it.
type registrationInput = {
  index: int,
  startBlock: int,
  endBlock: option<int>,
  interval: int,
  blockFieldMask: float,
}

let toRegistrationInputs = (onBlockRegistrations: array<Internal.onBlockRegistration>) =>
  onBlockRegistrations->Array.map(({index, startBlock, endBlock, interval, blockFieldMask}) => {
    index,
    // Resolved to the chain's start block by `ChainState` when absent.
    startBlock: startBlock->Option.getOr(0),
    endBlock,
    interval,
    blockFieldMask: blockFieldMask->Option.getOr(0.),
  })

// Back to the selection's own registrations, which the indexes come from.
let toInternalItems = (
  items: array<t>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>,
): array<Internal.item> =>
  switch items {
  | [] => []
  | items =>
    let byIndex = Dict.make()
    onBlockRegistrations->Array.forEach(reg => byIndex->Dict.set(reg.index->Int.toString, reg))
    items->Array.map(({blockNumber, onBlockRegistrationIndex}) => Internal.Block({
      onBlockRegistration: byIndex->Dict.getUnsafe(onBlockRegistrationIndex->Int.toString),
      blockNumber,
    }))
  }
