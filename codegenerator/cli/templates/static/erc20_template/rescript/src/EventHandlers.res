open Types

Handlers.ERC20.Approval.handler(async ({event, context}) => {
  let ownerAccount = await context.account.get(event.params.owner->Address.toString)

  if(ownerAccount->Belt.Option.isNone)
  {
    // setting Entities.Account.t object
    let accountObject: Entities.Account.t = {
      id: event.params.owner->Address.toString,
      balance: BigInt.fromInt(0),
    }

    // setting the account-entity with the new transfer field value
    context.account.set(accountObject)
  }

  let approvalId =
    event.params.owner->Address.toString ++ "-" ++ event.params.spender->Address.toString;

  let approvalObject: Entities.Approval.t = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner->Address.toString,
    spender_id: event.params.spender->Address.toString,
  };

  // this is the same for create or update as the amount is overwritten
  context.approval.set(approvalObject);
  
})

Handlers.ERC20.Transfer.handler(async ({event, context}) => {
  let senderAccount = await context.account.get(event.params.from->Address.toString)

  switch senderAccount {
  | Some(existingSenderAccount) => {
      // subtract the balance from the existing users balance
      let accountObject: Entities.Account.t = {
        id: existingSenderAccount.id,        
        balance: existingSenderAccount.balance->BigInt.sub(event.params.value),
      }
      context.account.set(accountObject)
    }

  | None => {
      // create the account
      // This is likely only ever going to be the zero address in the case of the first mint
      let accountObject: Entities.Account.t = {
        id: event.params.from->Address.toString,
        balance: BigInt.fromInt(0)->BigInt.sub(event.params.value),
      }

      // setting the account-entity with the new transfer field value
      context.account.set(accountObject)
    }
  }

  let receiverAccount = await context.account.get(event.params.to->Address.toString)

  switch receiverAccount {
  | Some(existingReceiverAccount) => {
      // update existing account's added balance
      let accountObject: Entities.Account.t = {
        id: existingReceiverAccount.id,        
        balance: existingReceiverAccount.balance->BigInt.add(event.params.value),
      }

      context.account.set(accountObject)
    }

  | None => {
      // create new account
      let accountObject: Entities.Account.t = {
        id: event.params.to->Address.toString,            
        balance: event.params.value,
      }

      context.account.set(accountObject)
    }
  }
})
