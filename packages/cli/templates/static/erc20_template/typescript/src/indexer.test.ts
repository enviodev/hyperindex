import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";
const { Addresses } = TestHelpers;

// `accounts` and `approvals` are materialized by `tables` in config.yaml, so
// there are no handlers to test — the config is the thing under test.
describe("Indexer Testing", () => {
  it("Should materialize accounts from the first ERC20 mint", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 10_861_674,
          endBlock: 10_861_674,
        },
      },
    });

    t.expect(
      await indexer.Accounts.getAll(),
      "The mint at block 10_861_674 debits the zero address and credits the recipient"
    ).toEqual([
      {
        id: "0x0000000000000000000000000000000000000000",
        balance: -1000000000000000000000000000n,
        chainId: 1,
      },
      {
        id: "0x41653c7d61609D856f29355E404F310Ec4142Cfb",
        balance: 1000000000000000000000000000n,
        chainId: 1,
      },
    ]);
  });
});

describe("Transfers", () => {
  it("Transfer subtracts the from account balance and adds to the to account balance", async (t) => {
    const indexer = createTestIndexer();

    const userAddress1 = Addresses.mockAddresses[0]!;
    const userAddress2 = Addresses.mockAddresses[1]!;

    // A balance is the sum of every contribution to it, so two transfers in
    // opposite directions leave userAddress1 at 5 - 3 = 2.
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: userAddress2, to: userAddress1, value: 5n },
            },
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: userAddress1, to: userAddress2, value: 3n },
            },
          ],
        },
      },
    });

    const account1 = await indexer.Accounts.getOrThrow(userAddress1, { chainId: 1 });
    const account2 = await indexer.Accounts.getOrThrow(userAddress2, { chainId: 1 });

    t.expect(
      { first: account1.balance, second: account2.balance },
      "userAddress1 receives 5 then sends 3"
    ).toEqual({ first: 2n, second: -2n });
  });
});

describe("Approvals", () => {
  it("Approval records the amount and creates both accounts", async (t) => {
    const indexer = createTestIndexer();

    const owner = Addresses.mockAddresses[0]!;
    const spender = Addresses.mockAddresses[1]!;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Approval",
              params: { owner, spender, value: 100n },
            },
          ],
        },
      },
    });

    t.expect({
      approvals: await indexer.Approvals.getAll(),
      // `_ref` doesn't create the referenced row, so the config contributes a
      // zero-valued balance change for each side of the approval.
      accounts: await indexer.Accounts.getAll(),
    }).toEqual({
      approvals: [
        {
          id: `${owner}-${spender}`,
          amount: 100n,
          owner_id: owner,
          spender_id: spender,
          chainId: 1,
        },
      ],
      accounts: [
        { id: owner, balance: 0n, chainId: 1 },
        { id: spender, balance: 0n, chainId: 1 },
      ],
    });
  });
});
