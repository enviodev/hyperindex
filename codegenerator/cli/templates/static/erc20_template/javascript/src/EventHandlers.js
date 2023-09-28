let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.Approval.loader((event, context) => {
  // loading the required Account entity
  context.Account.ownerAccountChangesLoad(event.params.owner);
});

ERC20Contract.Approval.handler((event, context) => {
  //  getting the owner Account entity
  let ownerAccount = context.Account.ownerAccountChanges;

  if (ownerAccount !== undefined) {
    // setting Account entity object
    let accountObject = {
      id: ownerAccount.id,
      approval: event.params.value,
      balance: ownerAccount.balance,
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  } else {
    // setting Account entity object
    let accountObject = {
      id: event.params.owner,
      balance: BigInt(0),
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  }
  let approvalId = event.params.owner + "-" + event.params.spender;

  let approvalObject = {
    id: approvalId,
    amount: event.params.value,
    owner: event.params.owner,
    spender: event.params.spender,
  };

  // this is the same for create or update as the amount is overwritten
  context.approval.set(approvalObject);
});

ERC20Contract.Transfer.loader((event, context) => {
  // loading the required Account entity
  context.Account.senderAccountChangesLoad(event.params.from.toString());
  context.Account.receiverAccountChangesLoad(event.params.to.toString());
});

ERC20Contract.Transfer.handler((event, context) => {
  // getting the sender Account entity
  let senderAccount = context.Account.senderAccountChanges;

  if (senderAccount !== undefined) {
    // setting the totals field value
    // setting Account entity object
    let accountObject = {
      id: event.params.from,
      balance: BigInt(0) - event.params.value,
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  } else {
    // setting Account entity object
    let accountObject = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  }

  // getting the sender Account entity
  let receiverAccount = context.Account.receiverAccountChanges;

  if (receiverAccount !== undefined) {
    // setting Account entity object
    let accountObject = {
      id: receiverAccount.id,
      approval: receiverAccount.approval,
      balance: BigInt(
        Number(receiverAccount.balance) + Number(event.params.value)
      ),
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  } else {
    // setting Account entity object
    let accountObject = {
      id: event.params.to.toString(),
      approval: BigInt(0),
      balance: event.params.value,
    };
    context.account.set(accountObject);
  } else {
    // update existing account
    let accountObject = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    // setting the Account entity with the new transfer field value
    context.Account.set(accountObject);
  }
});
