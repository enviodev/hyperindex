// Write-only variant of the erc20 template handlers.
//
// The template's handlers read entities back (`context.Account.get`) to
// accumulate balances. ClickHouse-backed entities are write-only, so that
// workload cannot run on the ClickHouse side at all. Dropping the reads keeps
// the exact write shape of the template — two Account sets per Transfer, one
// Account + one Approval set per Approval — while letting both backends run the
// identical batch of changes.
import { indexer, type Account, type Approval } from "envio";

indexer.onEvent(
  { contract: "ERC20", event: "Approval" },
  async ({ event, context }) => {
    const ownerAccount: Account = {
      id: event.params.owner,
      balance: 0n,
    };
    context.Account.set(ownerAccount);

    const approvalObject: Approval = {
      id: event.params.owner + "-" + event.params.spender,
      amount: event.params.value,
      owner_id: event.params.owner,
      spender_id: event.params.spender,
    };
    context.Approval.set(approvalObject);
  },
);

indexer.onEvent(
  { contract: "ERC20", event: "Transfer" },
  async ({ event, context }) => {
    context.Account.set({
      id: event.params.from,
      balance: 0n - event.params.value,
    });
    context.Account.set({
      id: event.params.to,
      balance: event.params.value,
    });
  },
);
