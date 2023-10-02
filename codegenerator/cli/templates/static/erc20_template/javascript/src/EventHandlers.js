let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.Approval.loader((event, context) => {
  // loading the required accountEntity
  context.account.load(event.params.owner);
});

ERC20Contract.Approval.handler((event, context) => {
  //  getting the owner accountEntity
  let ownerAccount = context.account.get(event.params.owner);

  if (ownerAccount == undefined) {
    // create the account
    // This is an unlikely scenario, but it is possible
    let accountObject = {
      id: event.params.owner,
      balance: BigInt(0),
    };

    context.account.set(accountObject);
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
  context.account.load(event.params.from);
  context.account.load(event.params.to);
});

ERC20Contract.Transfer.handler((event, context) => {
  let senderAccount = context.account.get(event.params.from);

  if (senderAccount == undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject = {
      id: event.params.from,
      balance: BigInt(0 - Number(event.params.value)),
    };

    context.account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject = {
      id: senderAccount.id,
      balance: BigInt(
        Number(senderAccount.balance) - Number(event.params.value)
      ),
    };
    context.account.set(accountObject);
  }

  // getting the sender accountEntity
  let receiverAccount = context.account.get(event.params.to);

  if (receiverAccount == undefined) {
    // create new account
    let accountObject = {
      id: event.params.to,
      balance: BigInt(event.params.value),
    };
    context.account.set(accountObject);
  } else {
    // update existing account
    let accountObject = {
      id: receiverAccount.id,
      balance: BigInt(
        Number(receiverAccount.balance) + Number(event.params.value)
      ),
    };

    context.account.set(accountObject);
  }
});
