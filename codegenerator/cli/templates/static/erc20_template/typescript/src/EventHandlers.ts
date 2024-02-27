import {
  ERC20Contract,
} from "../generated/src/Handlers.gen.ts";

import { AccountEntity, ApprovalEntity } from "../generated/src/Types.gen.ts";



ERC20Contract.Approval.loader(({ event, context }) => {
  // loading the required Account entity
  context.Account.load(event.params.owner.toString());
});

ERC20Contract.Approval.handler(({ event, context }) => {
  //  getting the owner Account entity
  let ownerAccount = context.Account.get(event.params.owner.toString());

  if (ownerAccount === undefined) {
    // Usually an accoun that is being approved alreay has/has had a balance, but it is possible they havent.

    // create the account
    let accountObject: AccountEntity = {
      id: event.params.owner.toString(),
      balance: 0n,
    };
    context.Account.set(accountObject);
  }

  let approvalId =
    event.params.owner.toString() + "-" + event.params.spender.toString();

  let approvalObject: ApprovalEntity = {
    id: approvalId,
    amount: event.params.value,
    owner_id: event.params.owner.toString(),
    spender_id: event.params.spender.toString(),
  };

  // this is the same for create or update as the amount is overwritten
  context.Approval.set(approvalObject);
});

ERC20Contract.Transfer.loader(({ event, context }) => {
  context.Account.load(event.params.from.toString());
  context.Account.load(event.params.to.toString());
});

ERC20Contract.Transfer.handler(({ event, context }) => {
  let senderAccount = context.Account.get(event.params.from.toString());

  if (senderAccount === undefined || senderAccount === null) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject: AccountEntity = {
      id: event.params.from.toString(),
      balance: 0n - event.params.value,
    };

    context.Account.set(accountObject);
  } else {
    // subtract the balance from the existing users balance
    let accountObject: AccountEntity = {
      id: senderAccount.id,
      balance: senderAccount.balance - event.params.value,
    };
    context.Account.set(accountObject);
  }

  let receiverAccount = context.Account.get(event.params.to.toString());

  if (receiverAccount === undefined || receiverAccount === null) {
    // create new account
    let accountObject: AccountEntity = {
      id: event.params.to.toString(),
      balance: event.params.value,
    };
    context.Account.set(accountObject);
  } else {
    // update existing account
    let accountObject: AccountEntity = {
      id: receiverAccount.id,
      balance: receiverAccount.balance + event.params.value,
    };

    context.Account.set(accountObject);
  }
});
