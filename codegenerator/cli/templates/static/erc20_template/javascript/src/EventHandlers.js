let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.Approval.loader((event, context) => {
  // loading the required Account entity
  context.Account.load(event.params.owner);
});

ERC20Contract.Approval.handler((event, context) => {
  //  getting the owner Account entity
  let ownerAccount = context.Account.get(event.params.owner);

  if (ownerAccount === undefined) {
    // Usually an accoun that is being approved alreay has/has had a balance, but it is possible they havent.

    // create the account
    let accountObject = {
      id: event.params.owner,
      balance: BigInt(0),
    };

    context.Account.set(accountObject);
  }
  let approvalId = event.params.owner + "-" + event.params.spender;

  let approvalObject = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner,
    spender_id: event.params.spender,
  };

  // this is the same for create or update as the amount is overwritten
  context.Approval.set(approvalObject);
});

ERC20Contract.Transfer.loader((event, context) => {
  context.Account.load(event.params.from);
  context.Account.load(event.params.to);
});

ERC20Contract.Transfer.handler((event, context) => {
  let senderAccount = context.Account.get(event.params.from);

  if (senderAccount === undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject = {
      id: event.params.from,
      balance: BigInt(0) - event.params.value,
    };

    context.Account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };
    context.Account.set(accountObject);
  }

  // getting the sender Account entity
  let receiverAccount = context.Account.get(event.params.to);

  if (receiverAccount === undefined) {
    // create new account
    let accountObject = {
      id: event.params.to,
      balance: event.params.value,
    };
    context.Account.set(accountObject);
  } else {
    // update existing account
    let accountObject = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    context.Account.set(accountObject);
  }
});
