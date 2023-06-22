let { ERC20Contract } = require("../generated/src/Handlers.bs.js");

ERC20Contract.registerApprovalLoadEntities((event, context) => {
  // loading the required accountEntity
  context.account.ownerAccountChangesLoad(event.params.owner);
});

ERC20Contract.registerApprovalHandler((event, context) => {
  //  getting the owner accountEntity
  let ownerAccount = context.account.ownerAccountChanges();

  if (ownerAccount != undefined) {
    // updating accountEntity object
    let accountObject = {
      id: ownerAccount.id,
      approval: event.params.value,
      balance: ownerAccount.balance,
    };

    // updating the accountEntity with the new transfer field value
    context.account.set(accountObject);
  } else {
    // updating accountEntity object
    let accountObject = {
      id: event.params.owner,
      approval: event.params.value,
      balance: BigInt(0),
    };

    // inserting the accountEntity with the new transfer field value
    context.account.set(accountObject);
  }
});

ERC20Contract.registerTransferLoadEntities((event, context) => {
  // loading the required accountEntity
  context.account.senderAccountChangesLoad(event.params.from.toString());
  context.account.receiverAccountChangesLoad(event.params.to.toString());
});

ERC20Contract.registerTransferHandler((event, context) => {
  // getting the sender accountEntity
  let senderAccount = context.account.senderAccountChanges();

  if (senderAccount != undefined) {
    // updating the totals field value
    // updating accountEntity object
    let accountObject = {
      id: senderAccount.id,
      approval: senderAccount.approval,
      balance: BigInt(
        Number(senderAccount.balance) - Number(event.params.value)
      ),
    };

    // updating the accountEntity with the new transfer field value
    context.account.set(accountObject);
  } else {
    // updating accountEntity object
    let accountObject = {
      id: event.params.from.toString(),
      approval: BigInt(0),
      balance: BigInt(0 - Number(event.params.value)),
    };

    // inserting the accountEntity with the new transfer field value
    context.account.set(accountObject);
  }

  // getting the sender accountEntity
  let receiverAccount = context.account.receiverAccountChanges();

  if (receiverAccount != undefined) {
    // updating accountEntity object
    let accountObject = {
      id: receiverAccount.id,
      approval: receiverAccount.approval,
      balance: BigInt(
        Number(receiverAccount.balance) + Number(event.params.value)
      ),
    };

    // updating the accountEntity with the new transfer field value
    context.account.set(accountObject);
  } else {
    // updating accountEntity object
    let accountObject = {
      id: event.params.to.toString(),
      approval: BigInt(0),
      balance: event.params.value,
    };

    // inserting the accountEntity with the new transfer field value
    context.account.set(accountObject);
  }
});
