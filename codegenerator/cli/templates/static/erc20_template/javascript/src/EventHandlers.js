let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.Approval.loader((event, context) => {
  // loading the required accountEntity
  context.Account.load(event.params.owner);
});

ERC20Contract.Approval.handler((event, context) => {
  //  getting the owner accountEntity
  let ownerAccount = context.Account.get(event.params.owner);

  if (ownerAccount === undefined) {
    // create the account
    // This is an unlikely scenario, but it is possible
    let accountObject = {
      id: event.params.owner,
      balance: BigInt(0),
    };

    // setting the AccountEntity with the new transfer field value
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
  // loading the required AccountEntity
  context.Account.load(event.params.from.toString());
  context.Account.load(event.params.to.toString());
});

ERC20Contract.Transfer.handler((event, context) => {
  // getting the sender AccountEntity
  let senderAccount = context.Account.senderAccountChanges;

  if (senderAccount !== undefined) {
    // setting the totals field value
    // setting AccountEntity object
    let accountObject = {
      id: event.params.from,
      balance: BigInt(0) - event.params.value,
    };

    // setting the AccountEntity with the new transfer field value
    context.Account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };

    // setting the AccountEntity with the new transfer field value
    context.Account.set(accountObject);
  }

  // getting the sender AccountEntity
  let receiverAccount = context.Account.receiverAccountChanges;

  if (receiverAccount !== undefined) {
    // setting AccountEntity object
    let accountObject = {
      id: receiverAccount.id,
      approval: receiverAccount.approval,
      balance: BigInt(
        Number(receiverAccount.balance) + Number(event.params.value)
      ),
    };

    // setting the AccountEntity with the new transfer field value
    context.Account.set(accountObject);
  } else {
    // setting AccountEntity object
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

    // setting the AccountEntity with the new transfer field value
    context.Account.set(accountObject);
  }
});
