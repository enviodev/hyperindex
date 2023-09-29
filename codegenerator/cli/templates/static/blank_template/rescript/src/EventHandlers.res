/*
 *Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
 */

// code below is purely for demonstration purposes
// please use it for reference only and delete it when you start working on your indexer

// Handlers.MyAwesomeContractContract.AwesomeEvent.loader((~event, ~context) => {
//   let _ = context.awesomeEntity.load(event.params.identifier)
// })

// Handlers.MyAwesomeContractContract.AwesomeEvent.handler((~event, ~context) => {
//   switch context.awesomeEntity.get(event.params.identifier) {
//   | Some({id, awesomeTotal}) =>
//     let updatedObject: Types.awesomeEntityEntity = {
//       id,
//       awesomeTotal: awesomeTotal->Ethers.BigInt.add(event.params.awesomeValue),
//       awesomeAddress: event.params.awesomeAddress->Ethers.ethAddressToString,
//     }

//     context.awesomeEntity.set(updatedObject)

//   | None =>
//     let awesomeEntityObject: Types.awesomeEntityEntity = {
//       id: event.params.identifier,
//       awesomeTotal: event.params.awesomeValue,
//       awesomeAddress: event.params.awesomeAddress->Ethers.ethAddressToString,
//     }

//     context.awesomeEntity.set(awesomeEntityObject)
//   }
// })
