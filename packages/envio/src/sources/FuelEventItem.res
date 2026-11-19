// One receipt a build delivers, with the params its handler receives.
type item = {
  receiptIndex: int,
  txId: string,
  blockHeight: int,
  srcAddress: Address.t,
  params: Internal.eventParams,
}

let toInternalItem = (
  item: item,
  ~onEventRegistration: Internal.onEventRegistration,
  ~chainId,
): Internal.item => {
  let {contractName, name: eventName} = onEventRegistration.eventConfig
  Internal.Event({
    onEventRegistration,
    chainId,
    blockNumber: item.blockHeight,
    logIndex: item.receiptIndex,
    // Fuel carries the transaction inline on the payload, by its id.
    transactionIndex: 0,
    payload: {
      contractName,
      eventName,
      chainId,
      params: item.params,
      transaction: {
        "id": item.txId,
      }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
      srcAddress: item.srcAddress,
      logIndex: item.receiptIndex,
    }->Fuel.fromPayload,
  })
}
