import {
  ERC20Contract_Approval_loader,
  ERC20Contract_Approval_handler,
  ERC20Contract_Transfer_loader,
  ERC20Contract_Transfer_handler,
} from "../generated/src/Handlers.gen";

import { accountEntity, approvalEntity } from "../generated/src/Types.gen";

ERC20Contract_Approval_loader(({ event, context }) => {
  context.account.load(event.params.owner.toString());
  context.approval.load(
    event.params.owner.toString() + "-" + event.params.spender.toString(),
    {}
  );
});

ERC20Contract_Approval_handler(({ event, context }) => {
  //  getting the owner accountEntity
  let ownerAccount = context.account.get(event.params.owner.toString());

  if (ownerAccount == undefined) {
    // create the account
    // This is an unlikely scenario, but it is possible
    let accountObject: accountEntity = {
      id: event.params.owner.toString(),
      balance: 0n,
    };
    context.account.set(accountObject);
  }

  let approvalId =
    event.params.owner.toString() + "-" + event.params.spender.toString();

  let approval = context.approval.get(approvalId);

  let approvalObject: approvalEntity = {
    id: approvalId,
    amount: event.params.value,
    owner: event.params.owner.toString(),
    spender: event.params.spender.toString(),
  };

  // this is the same for create or update as the amount is overwritten
  context.approval.set(approvalObject);
});

ERC20Contract_Transfer_loader(({ event, context }) => {
  context.account.load(event.params.from.toString());
  context.account.load(event.params.to.toString());
});

ERC20Contract_Transfer_handler(({ event, context }) => {
  let senderAccount = context.account.get(event.params.from.toString());

  if (senderAccount == undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject: accountEntity = {
      id: event.params.from.toString(),
      balance: 0n - event.params.value,
    };

    context.account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject: accountEntity = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };
    context.account.set(accountObject);
  }

  let receiverAccount = context.account.get(event.params.to.toString());

  if (receiverAccount == undefined) {
    // create new account
    let accountObject: accountEntity = {
      id: event.params.to.toString(),
      balance: event.params.value,
    };
    context.account.set(accountObject);
  } else {
    // update existing account
    let accountObject: accountEntity = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    context.account.set(accountObject);
  }
});
