import { describe, it, expect } from "vitest";
import { TestHelpers, createTestIndexer } from "generated";

const { MockDb, UniswapV3Factory, Addresses } = TestHelpers;

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
    const mockDb = MockDb.createMockDb();
    const token0 = Addresses.mockAddresses[0]!;
    const token1 = Addresses.mockAddresses[1]!;
    const pool = Addresses.mockAddresses[2]!;

    const mockEvent = UniswapV3Factory.PoolCreated.createMockEvent({
      token0,
      token1,
      fee: 500n,
      tickSpacing: 10n,
      pool,
    });

    const mockDbAfter = await UniswapV3Factory.PoolCreated.processEvent({
      event: mockEvent,
      mockDb,
    });

    const entityId = `${mockEvent.chainId}_${pool}`;
    const entity = mockDbAfter.entities.UniswapV3Factory_PoolCreated.get(entityId);

    expect(entity).toBeDefined();
    expect(entity?.token0).toBe(token0);
    expect(entity?.token1).toBe(token1);
    expect(entity?.fee).toBe(500n);
    expect(entity?.tickSpacing).toBe(10n);
    expect(entity?.pool).toBe(pool);
    // Effect falls back to 18 when RPC is not configured
    expect(entity?.token0Decimals).toBe(18);
    expect(entity?.token1Decimals).toBe(18);
  });

  it("uses pool address as part of the entity ID", async () => {
    const mockDb = MockDb.createMockDb();
    const pool = Addresses.mockAddresses[3]!;

    const mockEvent = UniswapV3Factory.PoolCreated.createMockEvent({ pool });
    const mockDbAfter = await UniswapV3Factory.PoolCreated.processEvent({
      event: mockEvent,
      mockDb,
    });

    const expectedId = `${mockEvent.chainId}_${pool}`;
    expect(
      mockDbAfter.entities.UniswapV3Factory_PoolCreated.get(expectedId)
    ).toBeDefined();
  });
});
