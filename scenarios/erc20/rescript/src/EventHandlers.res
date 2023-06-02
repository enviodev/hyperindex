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

  // creating a totalsEntity to store the event data
  let totalsObject: totalsEntity = {
    id: event.srcAddress,
    erc20: tokenObject.id,
    totalTransfer: Ethers.BigInt.fromInt(0),
  }

  // creating a new entry in totals table with the event data
  context.totals.insert(totalsObject)
})

Handlers.ERC20Contract.registerTransferLoadEntities((~event, ~context) => {
  // loading the required totalsEntity to update the totals field
  context.totals.totalChangesLoad(event.srcAddress)
})

Handlers.ERC20Contract.registerTransferHandler((~event, ~context) => {
  // getting the current totals field value
  let currentTotals = context.totals.totalChanges()

  switch currentTotals {
  | Some(existingTotals) => {
      // updating the totals field value
      let totalsObject: totalsEntity = {
        id: event.srcAddress,
        erc20: existingTotals.erc20,
        totalTransfer: existingTotals.totalTransfer -> Ethers.BigInt.add(event.params.value),
      }

      // updating the totalTransfers table with the new totals field value
      context.totals.update(totalsObject)
    }

  | None => ()
  }
})
