import { indexer, type Account, type Approval } from "envio";

indexer.onEvent(
  { contract: "ERC20", event: "Approval" },
  async ({ event, context }) => {
    //  getting the owner Account entity
    let ownerAccount = await context.Account.get(event.params.owner);

    if (ownerAccount === undefined) {
      // Usually an account that is being approved already has/has had a balance, but it is possible they haven't.

      // create the account
      let accountObject: Account = {
        id: event.params.owner,
        balance: 0n,
      };
      context.Account.set(accountObject);
    }

    let approvalId = event.params.owner + "-" + event.params.spender;

    let approvalObject: Approval = {
      id: approvalId,
      amount: event.params.value,
      owner_id: event.params.owner,
      spender_id: event.params.spender,
    };

    // this is the same for create or update as the amount is overwritten
    context.Approval.set(approvalObject);
  },
);

indexer.onEvent(
  { contract: "ERC20", event: "Transfer" },
  async ({ event, context }) => {
    let [senderAccount, receiverAccount] = await Promise.all([
      context.Account.get(event.params.from),
      context.Account.get(event.params.to),
    ]);

    if (senderAccount === undefined) {
      // create the account
      // This is likely only ever going to be the zero address in the case of the first mint
      let accountObject: Account = {
        id: event.params.from,
        balance: 0n - event.params.value,
      };

      context.Account.set(accountObject);
    } else {
      // subtract the balance from the existing users balance
      let accountObject: Account = {
        id: senderAccount.id,
        balance: senderAccount.balance - event.params.value,
      };
      context.Account.set(accountObject);
    }

    if (receiverAccount === undefined) {
      // create new account
      let accountObject: Account = {
        id: event.params.to,
        balance: event.params.value,
      };
      context.Account.set(accountObject);
    } else {
      // update existing account
      let accountObject: Account = {
        id: receiverAccount.id,
        balance: receiverAccount.balance + event.params.value,
      };

      context.Account.set(accountObject);
    }
  },
);
