const { ERC20 } = require("generated");

ERC20.Approval.handler(async ({ event, context }) => {
  //  getting the owner Account entity
  const ownerAccount = await context.Account.get(event.params.owner);

  if (ownerAccount === undefined) {
    // It's possible to call the approve function without having a balance of the token and hence the account doesn't exist yet

    // create the account
    const accountObject = {
      id: event.params.owner,
      balance: BigInt(0),
    };

    context.Account.set(accountObject);
  }
  const approvalId = event.params.owner + "-" + event.params.spender;

  const approvalObject = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner,
    spender_id: event.params.spender,
  };

  // this is the same for create or update as the amount is overwritten
  context.Approval.set(approvalObject);
});

ERC20.Transfer.handler(async ({ event, context }) => {
  const senderAccount = await context.Account.get(event.params.from);

  if (senderAccount === undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    const accountObject = {
      id: event.params.from,
      balance: BigInt(0) - event.params.value,
    };

    context.Account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    const accountObject = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };
    context.Account.set(accountObject);
  }

  // getting the sender Account entity
  const receiverAccount = await context.Account.get(event.params.to);

  if (receiverAccount === undefined) {
    // create new account
    const accountObject = {
      id: event.params.to,
      balance: event.params.value,
    };

    context.Account.set(accountObject);
  } else {
    // update existing account
    const accountObject = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    context.Account.set(accountObject);
  }
});
