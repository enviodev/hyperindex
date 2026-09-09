// What a test indexer reports about its chains, and the guards process() applies
// to a block range before it starts.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: process-guards
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Noop
        address: "0x0b2F78c5Bf6d9c12EE1225d5f374Aa91204580C3"
        events:
          - event: "EmptyEvent()"
  - id: 137
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "EmptyEvent()"
          - event: "TestEventWithReservedKeyword(string module)"
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Noop", event: "EmptyEvent" }, async () => {});
indexer.onEvent({ contract: "Gravatar", event: "EmptyEvent" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("TestIndexer chain info and process() guards", () => {
  it("exposes chain ids, metadata and contracts", (t) => {
    const indexer = createTestIndexer();
    const chain = indexer.chains[1];

    t.expect({
      chainIds: indexer.chainIds,
      chainKeys: Object.keys(indexer.chains),
      chain: {
        id: chain.id,
        name: chain.name,
        startBlock: chain.startBlock,
        endBlock: chain.endBlock,
        isRealtime: chain.isRealtime,
      },
      contractName: chain.Noop.name,
      addresses: chain.Noop.addresses,
      abiIsArray: Array.isArray(chain.Noop.abi),
      // The name-keyed alias is non-enumerable but resolves to the same object.
      nameAliasIsSameChain: indexer.chains[1] === indexer.chains.ethereumMainnet,
    }).toEqual({
      chainIds: [1, 137],
      chainKeys: ["1", "137"],
      chain: {
        id: 1,
        name: "ethereumMainnet",
        startBlock: 1,
        endBlock: undefined,
        isRealtime: false,
      },
      contractName: "Noop",
      addresses: ["0x0b2F78c5Bf6d9c12EE1225d5f374Aa91204580C3"],
      abiIsArray: true,
      nameAliasIsSameChain: true,
    });
  });

  it("processes a chain with no events into an empty change set", async (t) => {
    const indexer = createTestIndexer();

    t.expect(await indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } })).toEqual({
      changes: [],
    });
  });

  it("rejects a process() call naming no chain at all", (t) => {
    const indexer = createTestIndexer();

    t.expect(() => indexer.process({ chains: {} })).toThrowError(
      "createTestIndexer requires at least one chain to be defined"
    );
  });

  it("rejects a second process() while the first is still running", async (t) => {
    const indexer = createTestIndexer();
    const first = indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } });

    t.expect(() => indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100 } } })).toThrowError(
      "createTestIndexer process is already running. Only one process call is allowed at a time"
    );

    await first;
  });

  it("rejects a startBlock below the chain's configured start block", (t) => {
    const indexer = createTestIndexer();

    t.expect(() => indexer.process({ chains: { 1: { startBlock: 0, endBlock: 100 } } })).toThrowError(
      "Invalid block range for chain 1: startBlock (0) is less than config.startBlock (1). Either use startBlock >= 1 or create a new test indexer with createTestIndexer()."
    );
  });

  it("rejects a startBlock overlapping blocks a previous call processed", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [{ contract: "Gravatar", event: "EmptyEvent", block: { number: 100 } }],
        },
      },
    });

    t.expect(() =>
      indexer.process({ chains: { 137: { startBlock: 50, endBlock: 150 } } })
    ).toThrowError(
      "Invalid block range for chain 137: startBlock (50) must be greater than previously processed endBlock (100). Either use startBlock > 100 or create a new test indexer with createTestIndexer()."
    );
  });

  // Simulating an event nothing handles is almost always a typo or a forgotten
  // handler, so it fails loudly instead of processing nothing.
  it("rejects simulating an event with no registered handler", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(
        indexer.process({
          chains: {
            137: {
              startBlock: 1,
              endBlock: 100,
              simulate: [{ contract: "Gravatar", event: "TestEventWithReservedKeyword" }],
            },
          },
        })
      )
      .rejects.toThrow(
        'no handler runs for event "TestEventWithReservedKeyword" on contract "Gravatar"'
      );
  });
});
`,
)
