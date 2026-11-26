let isFetched = (reg: Internal.onBlockRegistration) => reg.blockFieldMask->Option.isSome

// Mirrors `BlockHandler::runs_on` in `chain_buffer/schedule.rs`.
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

type blockHandlerInput = {
  index: int,
  startBlock: int,
  endBlock: option<int>,
  interval: int,
  blockFieldMask: option<float>,
}

// Every block handler of a chain, as the buffer schedules their items.
let toBlockHandlerInputs = (onBlockRegistrations: array<Internal.onBlockRegistration>) =>
  onBlockRegistrations->Array.map(({index, startBlock, endBlock, interval, blockFieldMask}) => {
    index,
    // Resolved to the chain's start block by `ChainState` when absent.
    startBlock: startBlock->Option.getOr(0),
    endBlock,
    interval,
    blockFieldMask,
  })
