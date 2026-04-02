import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";
import { TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("UniswapV3Factory PoolCreated (integration)", () => {
  it("processes first PoolCreated event on Ethereum mainnet (block 12369739)", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 12_369_739,
          endBlock: 12_369_739,
        },
      },
    });

    expect(result.changes).toMatchInlineSnapshot(`
      [
        {
          "UniswapV3Factory_PoolCreated": {
            "sets": [
              {
                "fee": 3000n,
                "id": "1_0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                "pool": "0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                "tickSpacing": 60n,
                "token0": "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
                "token0Decimals": 18,
                "token1": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
                "token1Decimals": 18,
              },
            ],
          },
          "block": 12369739,
          "blockHash": "0xe8228e3e736a42c7357d2ce6882a1662c588ce608897dd53c3053bcbefb4309a",
          "chainId": 1,
          "eventsProcessed": 1,
        },
      ]
    `);
  });
});

describe("UniswapV3Factory PoolCreated (unit)", () => {
  it("creates an entity with the correct pool fields from a mock event", async () => {
    const indexer = createTestIndexer();
    const token0 = Addresses.mockAddresses[0];
    const token1 = Addresses.mockAddresses[1];
    const pool = Addresses.mockAddresses[2];

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "UniswapV3Factory",
              event: "PoolCreated",
              params: { token0, token1, fee: 500n, tickSpacing: 10n, pool },
            },
          ],
        },
      },
    });

    const entityId = `1_${pool}`;
    // Effect falls back to 18 when RPC is not configured
    expect(await indexer.UniswapV3Factory_PoolCreated.get(entityId)).toEqual({
      id: entityId,
      token0,
      token1,
      fee: 500n,
      tickSpacing: 10n,
      pool,
      token0Decimals: 18,
      token1Decimals: 18,
    });
  });

  it("uses pool address as part of the entity ID", async () => {
    const indexer = createTestIndexer();
    const pool = Addresses.mockAddresses[3];
    const token0 = Addresses.mockAddresses[4];
    const token1 = Addresses.mockAddresses[5];

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "UniswapV3Factory",
              event: "PoolCreated",
              params: { token0, token1, fee: 100n, tickSpacing: 1n, pool },
            },
          ],
        },
      },
    });

    expect(await indexer.UniswapV3Factory_PoolCreated.get(`1_${pool}`)).toBeDefined();
  });
});
