import { describe, it, expect } from "vitest";
import { createTestIndexer, TestHelpers, type Account } from "generated";
const { Addresses } = TestHelpers;

describe("Indexer Testing", () => {
  it("Should create accounts from ERC20 Transfer events", async () => {
    const indexer = createTestIndexer();

    expect(
      await indexer.process({
        chains: {
          1: {
            startBlock: 10_861_674,
            endBlock: 10_861_674,
          },
        },
      }),
      "Should find the first mint at block 10_861_674"
    ).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "Account": {
              "sets": [
                {
                  "balance": -1000000000000000000000000000n,
                  "id": "0x0000000000000000000000000000000000000000",
                },
                {
                  "balance": 1000000000000000000000000000n,
                  "id": "0x41653c7d61609D856f29355E404F310Ec4142Cfb",
                },
              ],
            },
            "block": 10861674,
            "blockHash": "0x32e4dd857b5b7e756551a00271e44b61dbda0a91db951cf79a3e58adb28f5c09",
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);

    expect(
      await indexer.process({
        chains: {
          1: {
            startBlock: 10_861_766,
            endBlock: 10_861_766,
          },
        },
      }),
      "Updates existing account balance on transfer"
    ).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "Account": {
              "sets": [
                {
                  "balance": 999999998000000000000000000n,
                  "id": "0x41653c7d61609D856f29355E404F310Ec4142Cfb",
                },
                {
                  "balance": 2000000000000000000n,
                  "id": "0xe5737257D9406019768167C26f5C6123864ceC1e",
                },
              ],
            },
            "block": 10861766,
            "blockHash": "0x51a1a8789536990bcca505f514e03d44af25022decb58224108894e981125abd",
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);
  });
});

describe("Transfers", () => {
  it("Transfer subtracts the from account balance and adds to the to account balance", async () => {
    const indexer = createTestIndexer();

    const userAddress1 = Addresses.mockAddresses[0]!;
    const userAddress2 = Addresses.mockAddresses[1]!;

    const mockAccountEntity: Account = {
      id: userAddress1,
      balance: 5n,
    };

    // Pre-set initial entity state
    indexer.Account.set(mockAccountEntity);

    await indexer.process({
      chains: {
        1: {
          startBlock: 10_861_674,
          endBlock: 10_861_674,
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: {
                from: userAddress1,
                to: userAddress2,
                value: 3n,
              },
            },
          ],
        },
      },
    });

    const account1Balance = (await indexer.Account.get(userAddress1))?.balance;
    expect(
      account1Balance,
      "Should have subtracted transfer amount 3 from userAddress1 balance 5"
    ).toBe(2n);

    const account2Balance = (await indexer.Account.get(userAddress2))?.balance;
    expect(
      account2Balance,
      "Should have added transfer amount 3 to userAddress2 balance 0"
    ).toBe(3n);
  });
});
