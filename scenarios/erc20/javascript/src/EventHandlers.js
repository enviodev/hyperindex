let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.registerCreationLoadEntities((event, context) => {
  context.tokens.tokensCreationLoad(event.srcAddress.toString());
});

ERC20Contract.registerCreationHandler((event, context) => {
  let tokenObject = {
    id: event.srcAddress.toString(),
    name: event.params.name.toString(),
    symbol: event.params.symbol.toString(),
    decimals: 18,
  };

  context.tokens.insert(tokenObject);
});

