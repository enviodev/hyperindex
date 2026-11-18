// The item of a decoded EVM log that matched `onEventRegistration`. Its
// `block` and `transaction` are left out of the payload: a batch reads them
// from the chain's stores.
let toInternalItem = (
  ~logIndex,
  ~srcAddress: Address.t,
  ~blockNumber,
  ~transactionIndex,
  ~params: Internal.eventParams,
  ~onEventRegistration: Internal.evmOnEventRegistration,
  ~chainId,
): Internal.item => Internal.Event({
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
