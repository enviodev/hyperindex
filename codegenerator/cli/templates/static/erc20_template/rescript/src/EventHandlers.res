open Types

Handlers.ERC20Contract.Approval.loader((~event, ~context) => {
  context.account.load(event.params.owner->Ethers.ethAddressToString)
})

Handlers.ERC20Contract.Approval.handler((~event, ~context) => {
  let ownerAccount = context.account.get(event.params.owner->Ethers.ethAddressToString)

  if(ownerAccount->Belt.Option.isNone)
  {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: event.params.owner->Ethers.ethAddressToString,
      balance: Ethers.BigInt.fromInt(0),
    }

    // setting the accountEntity with the new transfer field value
    context.account.set(accountObject)
  }

  let approvalId =
    event.params.owner->Ethers.ethAddressToString ++ "-" ++ event.params.spender->Ethers.ethAddressToString;

  let approvalObject: approvalEntity = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner->Ethers.ethAddressToString,
    spender_id: event.params.spender->Ethers.ethAddressToString,
  };

  // this is the same for create or update as the amount is overwritten
  context.approval.set(approvalObject);
  
})

Handlers.ERC20Contract.Transfer.loader((~event, ~context) => {
  context.account.load(event.params.from->Ethers.ethAddressToString)
  context.account.load(event.params.to->Ethers.ethAddressToString)
})

Handlers.ERC20Contract.Transfer.handler((~event, ~context) => {
  let senderAccount = context.account.get(event.params.from->Ethers.ethAddressToString)

  switch senderAccount {
  | Some(existingSenderAccount) => {
      // subtract the balance from the existing users balance
      let accountObject: accountEntity = {
        id: existingSenderAccount.id,        
        balance: existingSenderAccount.balance->Ethers.BigInt.sub(event.params.value),
      }
      context.account.set(accountObject)
    }

  | None => {
      // create the account
      // This is likely only ever going to be the zero address in the case of the first mint
      let accountObject: accountEntity = {
        id: event.params.from->Ethers.ethAddressToString,
        balance: Ethers.BigInt.fromInt(0)->Ethers.BigInt.sub(event.params.value),
      }

      // setting the accountEntity with the new transfer field value
      context.account.set(accountObject)
    }
  }

  let receiverAccount = context.account.get(event.params.to->Ethers.ethAddressToString)

  switch receiverAccount {
  | Some(existingReceiverAccount) => {
      // update existing account's added balance
      let accountObject: accountEntity = {
        id: existingReceiverAccount.id,        
        balance: existingReceiverAccount.balance->Ethers.BigInt.add(event.params.value),
      }

      context.account.set(accountObject)
    }

  | None => {
      // create new account
      let accountObject: accountEntity = {
        id: event.params.to->Ethers.ethAddressToString,            
        balance: event.params.value,
      }

      context.account.set(accountObject)
    }
  }
})
