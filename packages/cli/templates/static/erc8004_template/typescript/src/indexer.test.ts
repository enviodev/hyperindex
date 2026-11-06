import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";
const { Addresses } = TestHelpers;

describe("ERC-8004 template tests", () => {
  it("A Registered event creates an Agent with its URI", async (t) => {
    const indexer = createTestIndexer();
    const owner = Addresses.mockAddresses[0]!;

    await indexer.process({
      chains: {
        143: {
          simulate: [
            {
              contract: "IdentityRegistry",
              event: "Registered",
              params: {
                agentId: 1n,
                agentURI: "ipfs://agent-1",
                owner,
              },
            },
          ],
        },
      },
    });

    // Entities are per-chain (see `disable_default_cross_chain` in config.yaml),
    // so a row read outside a handler carries the chain it belongs to.
    const agent = await indexer.Agent.getOrThrow("1");
    t.expect(agent).toEqual({
      id: "1",
      agentId: 1n,
      owner,
      agentURI: "ipfs://agent-1",
      chainId: 143,
    });
  });

  it("A NewFeedback event captures the log-only feedback URI and hash", async (t) => {
    const indexer = createTestIndexer();
    const client = Addresses.mockAddresses[1]!;
    const feedbackHash = "0x" + "11".repeat(32);

    await indexer.process({
      chains: {
        143: {
          simulate: [
            {
              contract: "ReputationRegistry",
              event: "NewFeedback",
              params: {
                agentId: 1n,
                clientAddress: client,
                feedbackIndex: 1n,
                value: 5n,
                valueDecimals: 0n,
                indexedTag1: "quality",
                tag1: "quality",
                tag2: "",
                endpoint: "",
                feedbackURI: "ipfs://feedback-1",
                feedbackHash,
              },
            },
          ],
        },
      },
    });

    const id = `1-${client}-1`;
    const feedback = await indexer.Feedback.getOrThrow(id);
    t.expect(feedback).toEqual({
      id,
      agent_id: "1",
      clientAddress: client,
      value: 5n,
      valueDecimals: 0,
      feedbackURI: "ipfs://feedback-1",
      feedbackHash,
      chainId: 143,
    });
  });
});
