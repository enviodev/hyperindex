let toInternalItem = (
  item: FuelHyperSyncClient.EventItems.item,
  ~onEventRegistration: Internal.onEventRegistration,
  ~chainId,
): Internal.item => {
  let {contractName, name: eventName} = onEventRegistration.eventConfig
  Internal.Event({
    onEventRegistration,
    chainId,
    blockNumber: item.blockHeight,
    logIndex: item.receiptIndex,
    // Fuel carries the transaction inline on the payload; the store key is
    // unused (Fuel identifies transactions by hash, kept on the payload).
    transactionIndex: 0,
    payload: {
      contractName,
      eventName,
      chainId,
      params: item.params,
      transaction: {
        "id": item.txId,
      }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
      // `block` is omitted; it's materialised from the block store onto the
      // payload at batch prep (like EVM/SVM).
      srcAddress: item.srcAddress,
      logIndex: item.receiptIndex,
    }->Fuel.fromPayload,
  })
}
