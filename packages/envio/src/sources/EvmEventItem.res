// A decoded EVM log that routed to a registration, as both EVM sources return
// it. Everything else the log carried — its topics, its transaction hash, its
// block hash — is consumed on the Rust side, so what crosses the boundary is
// what an item is actually built from.
type t = {
  logIndex: int,
  srcAddress: Address.t,
  // Number of the block this log belongs to; the block itself is resolved from
  // the chain's block store, deduplicated across items sharing a block.
  blockNumber: int,
  // Key (with the block number) into the transaction store; the transaction
  // is resolved from the store on demand.
  transactionIndex: int,
  // The registration this log routed to, by chain-scoped index. Logs that
  // route to no registration never cross the boundary.
  onEventRegistrationIndex: int,
  params: Internal.eventParams,
}

// `block` and `transaction` are omitted from the payload: both sources leave
// them to be materialised from the per-chain stores at batch prep.
let toInternalItem = (
  item: t,
  ~onEventRegistration: Internal.evmOnEventRegistration,
  ~chainId,
): Internal.item => {
  let {transactionIndex, logIndex, srcAddress, blockNumber, params} = item

  Internal.Event({
    onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
    chainId,
    blockNumber,
    logIndex,
    transactionIndex,
    payload: {
      contractName: onEventRegistration.eventConfig.contractName,
      eventName: onEventRegistration.eventConfig.name,
      chainId,
      params,
      srcAddress,
      logIndex,
    }->Evm.fromPayload,
  })
}

// Both sources hand back items alongside the registrations they routed to, by
// chain-scoped index.
let toInternalItems = (
  items: array<t>,
  ~onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ~chainId,
): array<Internal.item> =>
  items->Array.map(item =>
    item->toInternalItem(
      ~onEventRegistration=onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex),
      ~chainId,
    )
  )
