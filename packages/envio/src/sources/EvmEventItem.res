// A decoded EVM log that routed to a registration, as the event store holds
// it.
type t = {
  logIndex: int,
  srcAddress: Address.t,
  // The block's fields are read from the chain's block store.
  blockNumber: int,
  // Key, with the block number, into the chain's transaction store.
  transactionIndex: int,
  // The registration this log routed to, by chain-scoped index.
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
