import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Indexer Testing", () => {
  it("Should register pool and handle swap events", async (t) => {
    const indexer = createTestIndexer();

    t.expect(
      await indexer.process({
        chains: { 1: { startBlock: 12_369_739, endBlock: 12_369_739 } },
      }),
      "Should register the UNI/ETH pool at block 12369739"
    ).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "addresses": {
              "sets": [
                {
                  "address": "0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801",
                  "contract": "UniswapV3Pool",
                },
              ],
            },
            "block": 12369739,
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);

    t.expect(
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
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);
  });
});
