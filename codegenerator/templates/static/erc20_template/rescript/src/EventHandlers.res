open Types

Handlers.ERC20Contract.Approval.loader((~event, ~context) => {
  // loading the required accountEntity
  context.account.load(event.params.owner->Ethers.ethAddressToString)
})

Handlers.ERC20Contract.Approval.handler((~event, ~context) => {
  //  getting the owner accountEntity
  let ownerAccount = context.account.ownerAccountChanges

  switch ownerAccount {
  | Some(existingAccount) => {
      // setting accountEntity object
      let accountObject: accountEntity = {
        id: existingAccount.id,
        approval: event.params.value,
        balance: existingAccount.balance,
      }

      // setting the accountEntity with the new transfer field value
      context.account.set(accountObject)
    }

  | None => {
      // setting accountEntity object
      let accountObject: accountEntity = {
        id: event.params.owner->Ethers.ethAddressToString,
        approval: event.params.value,
        balance: Ethers.BigInt.fromInt(0),
      }

      // setting the accountEntity with the new transfer field value
      context.account.set(accountObject)
    }
  }
})

Handlers.ERC20Contract.Transfer.loader((~event, ~context) => {
  // loading the required accountEntity
  context.account.load(event.params.from->Ethers.ethAddressToString)
  context.account.load(event.params.to->Ethers.ethAddressToString)
})

Handlers.ERC20Contract.Transfer.handler((~event, ~context) => {
  // getting the sender accountEntity
  let senderAccount = context.account.senderAccountChanges

  switch senderAccount {
  | Some(existingSenderAccount) => {
      // setting accountEntity object
      let accountObject: accountEntity = {
        id: existingSenderAccount.id,
        approval: existingSenderAccount.approval,
        balance: existingSenderAccount.balance->Ethers.BigInt.sub(event.params.value),
      }

      // setting the accountEntity with the new transfer field value
      context.account.set(accountObject)
    }

  | None => {
      // setting accountEntity object
        let accountObject: accountEntity = {
          id: event.params.from->Ethers.ethAddressToString,
          approval: Ethers.BigInt.fromInt(0),
          balance: Ethers.BigInt.fromInt(0) ->Ethers.BigInt.sub(event.params.value),
        }

        // setting the accountEntity with the new transfer field value
        context.account.set(accountObject)
    }
  }

  // getting the sender accountEntity
  let receiverAccount = context.account.receiverAccountChanges

  switch receiverAccount {
  | Some(existingReceiverAccount) => {
      // setting accountEntity object
      let accountObject: accountEntity = {
        id: existingReceiverAccount.id,
        approval: existingReceiverAccount.approval,
        balance: existingReceiverAccount.balance->Ethers.BigInt.add(event.params.value),
      }

      // setting the accountEntity with the new transfer field value
      context.account.set(accountObject)
    }

  | None => {
      // setting accountEntity object
          let accountObject: accountEntity = {
            id: event.params.to->Ethers.ethAddressToString,
            approval: Ethers.BigInt.fromInt(0),
            balance: event.params.value,
          }

          // setting the accountEntity with the new transfer field value
          context.account.set(accountObject)
    }
  }
})
