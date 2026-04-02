import { describe, it, expect } from "vitest";
import { createTestIndexer, type Transfer } from "generated";
import { TestHelpers } from "envio";

const { Addresses } = TestHelpers;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// In simulate mode, block number defaults to the chain's startBlock (22000000 for chain 1)
// and logIndex starts at 0 for the first event.
const FIRST_EVENT_ID = "1_22000000_0";

describe("Topic Filter Indexer", () => {
  it("indexes mint events (Transfer from zero address)", async () => {
    const indexer = createTestIndexer();
    const recipient = Addresses.mockAddresses[0]!;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: {
                from: ZERO_ADDRESS,
                to: recipient,
                value: 1_000_000n,
              },
            },
          ],
        },
      },
    });

    const expectedTransfer: Transfer = {
      id: FIRST_EVENT_ID,
      amount: 1_000_000n,
      from: ZERO_ADDRESS,
      to: recipient,
      contract: ZERO_ADDRESS,
      chainId: 1,
    };

    const transfer = await indexer.Transfer.getOrThrow(FIRST_EVENT_ID);
    expect(transfer).toEqual(expectedTransfer);
  });

  it("indexes burn events (Transfer to zero address)", async () => {
    const indexer = createTestIndexer();
    const sender = Addresses.mockAddresses[0]!;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: {
                from: sender,
                to: ZERO_ADDRESS,
                value: 500_000n,
              },
            },
          ],
        },
      },
    });

    const expectedTransfer: Transfer = {
      id: FIRST_EVENT_ID,
      amount: 500_000n,
      from: sender,
      to: ZERO_ADDRESS,
      contract: ZERO_ADDRESS,
      chainId: 1,
    };

    const transfer = await indexer.Transfer.getOrThrow(FIRST_EVENT_ID);
    expect(transfer).toEqual(expectedTransfer);
  });

  it("does not index regular transfers (neither mint nor burn)", async () => {
    const indexer = createTestIndexer();
    const sender = Addresses.mockAddresses[0]!;
    const recipient = Addresses.mockAddresses[1]!;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: {
                from: sender,
                to: recipient,
                value: 100n,
              },
            },
          ],
        },
      },
    });

    const transfer = await indexer.Transfer.get(FIRST_EVENT_ID);
    expect(transfer, "Regular transfer should not be indexed").toBeUndefined();
  });
});
