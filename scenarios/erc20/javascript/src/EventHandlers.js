let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.registerCreationLoadEntities((event, context) => {});

ERC20Contract.registerCreationHandler((event, context) => {
  let tokenObject = {
    id: event.srcAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    decimals: 18,
  };

  context.tokens.insert(tokenObject);

  // creating a totalsEntity to store the event data
  let totalsObject = {
    id: event.srcAddress,
    erc20: tokenObject.id,
    totalTransfer: BigInt(0),
  };

  // creating a new entry in totals table with the event data
  context.totals.insert(totalsObject);
});

ERC20Contract.registerTransferLoadEntities((event, context) => {
  // loading the required totalsEntity to update the totals field
  context.totals.totalChangesLoad(event.srcAddress);
});

ERC20Contract.registerTransferHandler((event, context) => {
  let currentTotals = context.totals.totalChangesLoad;

  if (currentTotals != undefined) {
    // updating the totals field value
    let totalsObject = {
      id: event.srcAddress,
      erc20: currentTotals.erc20,
      totalTransfer: BigInt(Number(currentTotalTransfer.totalTransfer) + Number(event.params.value)),
    };

    // updating the totalTransfers table with the new totals field value
    context.totals.update(totalsObject);

  } else {
  }
});
