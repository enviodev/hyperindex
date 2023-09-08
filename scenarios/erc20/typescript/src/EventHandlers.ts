import {
  ERC20Contract_Approval_loader,
  ERC20Contract_Approval_handler,
  ERC20Contract_Transfer_loader,
  ERC20Contract_Transfer_handler,
} from "../generated/src/Handlers.gen";

import { accountEntity } from "../generated/src/Types.gen";

ERC20Contract_Approval_loader(({ event, context }) => {
  // loading the required accountEntity
  context.account.ownerAccountChangesLoad(event.params.owner.toString());
});

ERC20Contract_Approval_handler(({ event, context: { account } }) => {
  //  getting the owner accountEntity

  let ownerAccount = account.ownerAccountChanges;

  console.log("ownerAccount", ownerAccount);

  if (ownerAccount != undefined) {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: ownerAccount.id,
      approval: event.params.value,
      balance: ownerAccount.balance,
    };

    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  } else {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: event.params.owner.toString(),
      approval: event.params.value,
      balance: 0n,
    };

    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  }
});

ERC20Contract_Transfer_loader(({ event, context }) => {
  // loading the required accountEntity
  context.account.senderAccountChangesLoad(event.params.from.toString());
  context.account.receiverAccountChangesLoad(event.params.to.toString());
});

ERC20Contract_Transfer_handler(({ event, context: { account } }) => {
  // getting the sender accountEntity
  let senderAccount = account.senderAccountChanges;

  if (senderAccount != undefined) {
    // setting the totals field value
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: senderAccount.id,
      approval: senderAccount.approval,
      balance: senderAccount.balance - event.params.value,
    };
    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  } else {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: event.params.from.toString(),
      approval: 0n,
      balance: 0n - event.params.value,
    };

    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  }

  // getting the sender accountEntity
  let receiverAccount = account.receiverAccountChanges;

  if (receiverAccount != undefined) {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: receiverAccount.id,
      approval: receiverAccount.approval,
      balance: receiverAccount.balance + event.params.value,
    };

    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  } else {
    // setting accountEntity object
    let accountObject: accountEntity = {
      id: event.params.to.toString(),
      approval: 0n,
      balance: event.params.value,
    };

    // setting the accountEntity with the new transfer field value
    account.set(accountObject);
  }
});
