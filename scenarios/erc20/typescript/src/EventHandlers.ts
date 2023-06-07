import {
  ERC20Contract_registerApprovalLoadEntities,
  ERC20Contract_registerApprovalHandler,
  ERC20Contract_registerTransferHandler,
  ERC20Contract_registerTransferLoadEntities,
} from "../generated/src/Handlers.gen";

import { accountEntity } from "../generated/src/Types.gen";

ERC20Contract_registerApprovalLoadEntities(({ event, context }) => {
  // loading the required accountEntity
  context.account.ownerAccountChangesLoad(event.params.owner.toString());
});

ERC20Contract_registerApprovalHandler(({ event, context }) => {
  //  getting the owner accountEntity
  let ownerAccount = context.account.ownerAccountChanges();

  if (ownerAccount != undefined) {
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: ownerAccount.id,
      approval: event.params.value,
      balance: ownerAccount.balance,
    };

    // updating the accountEntity with the new transfer field value
    context.account.update(accountObject);
  } else {
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: event.params.owner.toString(),
      approval: event.params.value,
      balance: BigInt(0),
    };

    // inserting the accountEntity with the new transfer field value
    context.account.insert(accountObject);
  }
});

ERC20Contract_registerTransferLoadEntities(({ event, context }) => {
  // loading the required accountEntity
  context.account.senderAccountChangesLoad(event.params.from.toString());
  context.account.receiverAccountChangesLoad(event.params.to.toString());
});

ERC20Contract_registerTransferHandler(({ event, context }) => {
  // getting the sender accountEntity
  let senderAccount = context.account.senderAccountChanges();

  if (senderAccount != undefined) {
    // updating the totals field value
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: senderAccount.id,
      approval: senderAccount.approval,
      balance: BigInt(
        Number(senderAccount.balance) - Number(event.params.value)
      ),
    };

    // updating the accountEntity with the new transfer field value
    context.account.update(accountObject);
  } else {
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: event.params.from.toString(),
      approval: BigInt(0),
      balance: BigInt(0 - Number(event.params.value)),
    };

    // inserting the accountEntity with the new transfer field value
    context.account.insert(accountObject);
  }

  // getting the sender accountEntity
  let receiverAccount = context.account.receiverAccountChanges();

  if (receiverAccount != undefined) {
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: receiverAccount.id,
      approval: receiverAccount.approval,
      balance: BigInt(
        Number(receiverAccount.balance) + Number(event.params.value)
      ),
    };

    // updating the accountEntity with the new transfer field value
    context.account.update(accountObject);
  } else {
    // updating accountEntity object
    let accountObject: accountEntity = {
      id: event.params.to.toString(),
      approval: BigInt(0),
      balance: event.params.value,
    };

    // inserting the accountEntity with the new transfer field value
    context.account.insert(accountObject);
  }
});
