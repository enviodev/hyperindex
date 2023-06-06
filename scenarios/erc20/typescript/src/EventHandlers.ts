import {
  ERC20Contract_registerCreationHandler,
  ERC20Contract_registerCreationLoadEntities,
  ERC20Contract_registerTransferHandler,
  ERC20Contract_registerTransferLoadEntities,
} from "../generated/src/Handlers.gen";

import {
  tokensEntity,
  totalsEntity
} from "../generated/src/Types.gen";

ERC20Contract_registerCreationLoadEntities(({ event, context }) => {
});

ERC20Contract_registerCreationHandler(({ event, context }) => {
  // creating a erc20TokenEntity to store the event data
  let tokenObject: tokensEntity = {
    id: event.srcAddress.toString(),
    name: event.params.name.toString(),
    symbol: event.params.symbol.toString(),
    decimals: 18,
  };

  // creating a new entry in erc20Token table with the event data
  context.tokens.insert(tokenObject);
  
  // creating a totalsEntity to store the event data
  let totalsObject: totalsEntity= {
    id: event.srcAddress.toString(),
    erc20: tokenObject.id,
    totalTransfer: BigInt(0),
  };
  
  // creating a new entry in totals table with the event data
  context.totals.insert(totalsObject);
});

ERC20Contract_registerTransferLoadEntities(({ event, context }) => {
  // loading the required totalsEntity to update the totals field
  context.totals.totalChangesLoad(event.srcAddress.toString());
});

ERC20Contract_registerTransferHandler(({ event, context }) => {
  // getting the current totals field value
  let currentTotalTransfer = context.totals.totalChanges();

  if (currentTotalTransfer != null) {
    // updating the totals field value
    let totalsObject: totalsEntity = {
      id: event.srcAddress.toString(),
      erc20: currentTotalTransfer.erc20,
      totalTransfer: BigInt(Number(currentTotalTransfer.totalTransfer) + Number(event.params.value))
    };

    // updating the totalTransfers table with the new totals field value
    context.totals.update(totalsObject);
  } else {
  }
});
