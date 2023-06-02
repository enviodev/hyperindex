let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.registerCreationLoadEntities((event, context) => {});

ERC20Contract.registerCreationHandler((event, context) => {
  let tokenObject = {
    id: event.srcAddress.toString(),
    name: event.params.name.toString(),
    symbol: event.params.symbol.toString(),
    decimals: 18,
  };

  context.tokens.insert(tokenObject);

  // creating a totalsEntity to store the event data
  let totalsObject = {
    id: event.srcAddress.toString(),
    erc20: tokenObject.id,
    totalTransfer: BigInt(0),
  };

  // creating a new entry in totals table with the event data
  context.totals.insert(totalsObject);
});

ERC20Contract.registerTransferLoadEntities((event, context) => {
  // loading the required totalsEntity to update the totals field
  context.totals.totalChangesLoad(event.srcAddress.toString());
});

ERC20Contract.registerTransferHandler((event, context) => {
  let currentTotals = context.totals.totalChangesLoad;

  if (currentTotals != undefined) {
    // updating the totals field value
    let totalsObject = {
      id: event.srcAddress.toString(),
      erc20: currentTotals.erc20,
      totalTransfer: currentTotals.totalTransfer + event.params.value,
    };

    // updating the totalTransfers table with the new totals field value
    context.totals.update(totalsObject);

  } else {
    let totalsObject = {
      id: event.srcAddress.toString(),
      erc20: event.srcAddress.toString(),
      totalTransfer: event.params.value,
    };

    // updating the totalTransfers table with the new totals field value
    context.totals.insert(totalsObject);
  }
});
