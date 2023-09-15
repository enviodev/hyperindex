/*
 *Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
 */

// code below is purely for demonstration purposes
// please use it for reference only and delete it when you start working on your indexer

// import {
//   MyAwesomeContractContract_AwesomeEvent_loader,
//   MyAwesomeContractContract_AwesomeEvent_handler,
// } from "../generated/src/Handlers.gen";

// import { awesomeEntityEntity } from "../generated/src/Types.gen";

// MyAwesomeContractContract_AwesomeEvent_loader(({ event, context }) => {
//   context.AwesomeEntity.load(event.params.identifier);
// });

// MyAwesomeContractContract_AwesomeEvent_handler(({ event, context }) => {
//   let awesomeEventObject = context.AwesomeEntity.get(event.params.identifier);
//   if (!!awesomeEventObject) {
//     const updatedEntity = {
//       id: awesomeEventObject.id,
//       awesomeAddress: event.params.awesomeAddress,
//       awesomeTotal: event.params.awesomeValue + awesomeEventObject.awesomeTotal,
//     };
//     context.AwesomeEntity.set(updatedEntity);
//   } else {
//     const awesomeEntityObject = {
//       id: event.params.identifier,
//       awesomeAddress: event.params.awesomeAddress,
//       awesomeTotal: event.params.awesomeValue,
//     };
//     context.AwesomeEntity.set(awesomeEntityObject);
//   }
// });
