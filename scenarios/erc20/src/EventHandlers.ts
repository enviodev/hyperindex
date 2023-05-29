import {
  ERC20Contract_registerCreationHandler,
  ERC20Contract_registerCreationLoadEntities,
  ERC20Contract_registerTransferHandler,
  ERC20Contract_registerTransferLoadEntities,
} from "../generated/src/Handlers.gen";

import {
  erc20TokenEntity,
  totalTransfersEntity,
} from "../generated/src/Types.gen";

ERC20Contract_registerCreationLoadEntities(({ event, context }) => {});

ERC20Contract_registerCreationHandler(({ event, context }) => {

  // creating a erc20TokenEntity to store the event data
  let erc20TokenObject: erc20TokenEntity = {
    id: event.srcAddress.toString(),
    name: event.params.name.toString(),
    symbol: event.params.symbol.toString(),
    decimals: 18,
  };
  
  // creating a new entry in erc20Token table with the event data
  context.erc20Token.insert(erc20TokenObject);
  
  // creating a totalTransfersEntity to store the event data
  let totalTransferObject: totalTransfersEntity = {
    id: event.srcAddress.toString(),
    erc20: erc20TokenObject,
    totalTransfer: 0,
  };
  
  // creating a new entry in totalTransfers table with the event data
  context.totalTransfers.insert(totalTransferObject);
});

ERC20Contract_registerTransferLoadEntities(({ event, context }) => {
  // loading the required totalTransfersEntity to update the totalTransfer field
  context.totalTransfers.totalTransferChangesLoad(event.srcAddress.toString());
});

ERC20Contract_registerTransferHandler(({ event, context }) => {
  // getting the current totalTransfer field value
  let currentTotalTransfer = context.totalTransfers.totalTransferChanges();

  if (currentTotalTransfer != null) {
    // updating the totalTransfer field value
    let totalTransferObject: totalTransfersEntity = {
      id: event.srcAddress.toString(),
      erc20: currentTotalTransfer.erc20,
      totalTransfer: currentTotalTransfer.totalTransfer + Number(event.params.value),
    };

    // updating the totalTransfers table with the new totalTransfer field value
    context.totalTransfers.update(totalTransferObject);
  } else {
  }
});
