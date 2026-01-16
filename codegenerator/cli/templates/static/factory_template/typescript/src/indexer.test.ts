import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer Testing", () => {
  it("Should register pool and handle swap events", async () => {
    const indexer = createTestIndexer();

    expect(
      await indexer.process({
        chains: { 1: { startBlock: 12_369_739, endBlock: 12_369_739 } },
      }),
      "Should register the UNI/ETH pool at block 12369739"
    ).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "block": 12369739,
            "blockHash": "0xe8228e3e736a42c7357d2ce6882a1662c588ce608897dd53c3053bcbefb4309a",
            "chainId": 1,
            "dynamic_contract_registry": {
              "sets": [
                {
                  "chain_id": 1,
                  "contract_address": "0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                  "contract_name": "UniswapV3Pool",
                  "id": "1-0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                  "registering_event_block_number": 12369739,
                  "registering_event_block_timestamp": 1620157956,
                  "registering_event_contract_name": "UniswapV3Factory",
                  "registering_event_log_index": 24,
                  "registering_event_name": "PoolCreated",
                  "registering_event_src_address": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
                },
              ],
            },
            "eventsProcessed": 1,
          },
        ],
      }
    `);

    expect(
      await indexer.process({
        chains: { 1: { startBlock: 12_373_187, endBlock: 12_373_187 } },
      }),
      "Should handle swap event on the registered pool at block 12373187"
    ).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "UniswapV3Pool_Swap": {
              "sets": [
                {
                  "amount0": -3000000000000000000n,
                  "amount1": 39159647513529870n,
                  "chainId": 1,
                  "id": "1_12373187_275",
                  "liquidity": 13823839187817749392n,
                  "pool": "0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                  "recipient": "0x0459B3FBf7c1840ee03a63ca4AA95De48322322e",
                  "sender": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
                  "sqrtPriceX96": 9150855777021942113750115245n,
                },
              ],
            },
            "block": 12373187,
            "blockHash": "0xa59d3514ffb6d938a263cd99a34c715f21ea8446d29c21a5b15e619d783f563e",
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);
  });
});
