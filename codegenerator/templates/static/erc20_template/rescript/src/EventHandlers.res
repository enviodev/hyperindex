open Types

Handlers.ERC20Contract.registerCreationLoadEntities((~event, ~context) => {
  context.tokens.tokensCreationLoad(event.srcAddress)
})

Handlers.ERC20Contract.registerCreationHandler((~event, ~context) => {
  let tokenObject: tokensEntity = {
    id: event.srcAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    decimals: 18,
  }

  context.tokens.insert(tokenObject)
})
