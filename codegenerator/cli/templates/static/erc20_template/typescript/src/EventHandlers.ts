import {
  ERC20Contract_Approval_loader,
  ERC20Contract_Approval_handler,
  ERC20Contract_Transfer_loader,
  ERC20Contract_Transfer_handler,
} from "../generated/src/Handlers.gen";

import { AccountEntity } from "../generated/src/Types.gen";

ERC20Contract_Approval_loader(({ event, context }) => {
  // loading the required Account entity
  context.Account.ownerAccountChangesLoad(event.params.owner.toString());
});

ERC20Contract_Approval_handler(({ event, context: { Account } }) => {
  //  getting the owner Account entity

  let ownerAccount = Account.ownerAccountChanges;

  if (ownerAccount !== undefined) {
    // setting Account entity object
    let accountObject: AccountEntity = {
      id: ownerAccount.id,
      approval: event.params.value,
      balance: ownerAccount.balance,
    };

    // setting the Account entity with the new transfer field value
    Account.set(accountObject);
  } else {
    // setting Account entity object
    let accountObject: AccountEntity = {
      id: event.params.owner.toString(),
      balance: 0n,
    };

    // setting the Account entity with the new transfer field value
    Account.set(accountObject);
  }

  let approvalId =
    event.params.owner.toString() + "-" + event.params.spender.toString();

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
<<<<<<< HEAD
<<<<<<< HEAD
  context.account.load(event.params.from.toString());
  context.account.load(event.params.to.toString());
});

ERC20Contract_Transfer_handler(({ event, context }) => {
  let senderAccount = context.account.get(event.params.from.toString());

  if (senderAccount === undefined) {
    // create the account
    // This is likely only ever going to be the zero address in the case of the first mint
    let accountObject: accountEntity = {
=======
  // loading the required AccountEntity
=======
  // loading the required Account entity
>>>>>>> bff809ca (Correcting comment on entity)
      context.Account.senderAccountChangesLoad(event.params.from.toString());
      context.Account.receiverAccountChangesLoad(event.params.to.toString());
    });

ERC20Contract_Transfer_handler(({ event, context: { Account } }) => {
  // getting the sender Account entity
  let senderAccount = Account.senderAccountChanges;

  if (senderAccount !== undefined) {
    // setting the totals field value
    // setting Account entity object
    let accountObject: AccountEntity = {
      id: senderAccount.id,
      approval: senderAccount.approval,
      balance: senderAccount.balance - event.params.value,
    };
    // setting the Account entity with the new transfer field value
    Account.set(accountObject);
  } else {
    // setting Account entity object
    let accountObject: AccountEntity = {
>>>>>>> b1090d38 (Update templates with new layout for capitalization)
      id: event.params.from.toString(),
      balance: 0n - event.params.value,
    };

<<<<<<< HEAD
<<<<<<< HEAD
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

  if (receiverAccount === undefined) {
    // create new account
    let accountObject: accountEntity = {
      id: event.params.to.toString(),
      balance: event.params.value,
    };
    context.account.set(accountObject);
  } else {
    // update existing account
    let accountObject: accountEntity = {
=======
    // setting the AccountEntity with the new transfer field value
=======
    // setting the Account entity with the new transfer field value
>>>>>>> bff809ca (Correcting comment on entity)
      Account.set(accountObject);
    }

    // getting the sender Account entity
    let receiverAccount = Account.receiverAccountChanges;

    if (receiverAccount !== undefined) {
      // setting Account entity object
      let accountObject: AccountEntity = {
>>>>>>> b1090d38 (Update templates with new layout for capitalization)
        id: receiverAccount.id,
        balance: receiverAccount.balance + event.params.value,
      };

<<<<<<< HEAD
<<<<<<< HEAD
      context.account.set(accountObject);
=======
    // setting the AccountEntity with the new transfer field value
=======
    // setting the Account entity with the new transfer field value
>>>>>>> bff809ca (Correcting comment on entity)
      Account.set(accountObject);
    } else {
      // setting Account entity object
      let accountObject: AccountEntity = {
        id: event.params.to.toString(),
        approval: 0n,
        balance: event.params.value,
      };

      // setting the Account entity with the new transfer field value
      Account.set(accountObject);
>>>>>>> b1090d38 (Update templates with new layout for capitalization)
    }
  });
