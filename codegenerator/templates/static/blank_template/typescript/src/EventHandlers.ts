/*
*Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
*/

import {
  MyAwesomeContractContract_AwesomeEvent_loader,
  MyAwesomeContractContract_AwesomeEvent_handler,
} from "../generated/src/Handlers.gen";


import { awesomeEntityEntity } from "../generated/src/Types.gen";

MyAwesomeContractContract_AwesomeEvent_loader(({ event, context }) => {
  context.awesomeEntity.load(event.params.awesomeEventEntityId)
});

MyAwesomeContractContract_AwesomeEvent_handler(({ event, context }) => {
  let awesomeEventObject = context.awesomeEntity.get(event.params.awesomeEventEntityId);
  if (!!awesomeEventObject) {
    const updatedEntity = {
      id: awesomeEventObject.id,
      awesomeAddress: event.params.awesomeAddress,
      awesomeTotal: event.params.awesomeValue + awesomeEventObject.awesomeTotal
    }
    context.awesomeEntity.set(updatedEntity);
  } else {
    const awesomeEntityObject = {
      id: event.params.identifier,
      awesomeAddress: event.params.awesomeAddress,
      awesomeTotal: event.params.awesomeValue
    }
    context.awesomeEntity.set(awesomeEntityObject);
  }
});

