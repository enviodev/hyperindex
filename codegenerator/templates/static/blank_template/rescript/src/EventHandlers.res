/*
*Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
*/

Handlers.MyAwesomeContractContract.AwesomeEvent.loader((~event, ~context) => {
  let _ = context.awesomeEntity.load(event.params.awesomeEventEntityId)
})

Handlers.MyAwesomeContractContract.AwesomeEvent.handler((~event, ~context) => {
  switch context.awesomeEntity.get(event.params.awesomeEventEntityId) {
  | Some({id, awesomeTotal}) =>
    let updatedObject: Types.awesomeEntityEntity = {
      id,
      awesomeTotal: awesomeTotal->Ethers.BigInt.add(event.params.awesomeValue),
      awesomeAddress: event.params.awesomeAddress->Ethers.ethAddressToString,
    }

    context.awesomeEntity.set(updatedObject)

  | None =>
    let awesomeEntityObject: Types.awesomeEntityEntity = {
      id: event.params.identifier,
      awesomeTotal: event.params.awesomeValue,
      awesomeAddress: event.params.awesomeAddress->Ethers.ethAddressToString,
    }

    context.awesomeEntity.set(awesomeEntityObject)
  }
})
