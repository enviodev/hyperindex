import { ERC20, Account, Approval } from "generated";

ERC20.Approval.handler(async ({ event, context }) => {
  //  getting the owner Account entity
  let ownerAccount = await context.Account.get(event.params.owner.toString());

  if (ownerAccount === undefined) {
    // Usually an account that is being approved already has/has had a balance, but it is possible they haven't.

    // create the account
    let accountObject: Account = {
      id: event.params.owner.toString(),
      balance: 0n,
    };
    context.Account.set(accountObject);
  }

  let approvalId =
    event.params.owner.toString() + "-" + event.params.spender.toString();

  let approvalObject: Approval = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner.toString(),
    spender_id: event.params.spender.toString(),
  };

  // this is the same for create or update as the amount is overwritten
  context.Approval.set(approvalObject);
});

ERC20.Transfer.handler(async ({ event, context }) => {
  let senderAccount = await context.Account.get(event.params.from.toString());

  if (senderAccount === undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject: Account = {
      id: event.params.from.toString(),
      balance: 0n - event.params.value,
    };

    context.Account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject: Account = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };
    context.Account.set(accountObject);
  }

  let receiverAccount = await context.Account.get(event.params.to.toString());

  if (receiverAccount === undefined) {
    // create new account
    let accountObject: Account = {
      id: event.params.to.toString(),
      balance: event.params.value,
    };
    context.Account.set(accountObject);
  } else {
    // update existing account
    let accountObject: Account = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    context.Account.set(accountObject);
  }
});
