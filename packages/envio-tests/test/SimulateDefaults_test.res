// How a simulate item is filled in: block numbers and log indexes when they are
// left off, event params when they are partial or absent, and the order chains
// are processed in.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: simulate-defaults
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
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
          - event: "TestEvent(uint256 id, address user, (string name, string email) contactDetails)"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
  displayName: String!
  imageUrl: String!
}

type SimulateTestEvent {
  id: ID!
  blockNumber: Int!
  logIndex: Int!
  timestamp: Int!
}

type SimpleEntity {
  id: ID!
  value: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Noop", event: "EmptyEvent" }, async () => {});

indexer.onEvent({ contract: "Gravatar", event: "EmptyEvent" }, async ({ event, context }) => {
  context.SimulateTestEvent.set({
    id: event.block.number + "_" + event.logIndex,
    blockNumber: event.block.number,
    logIndex: event.logIndex,
    timestamp: event.block.timestamp,
  });
});

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  context.Gravatar.set({
    id: event.params.id.toString(),
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  });
});

// https://github.com/enviodev/hyperindex/issues/538 — a struct param has to
// reach the handler as a named record. Delivered as a positional tuple, the
// property reads below would be undefined.
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.SimpleEntity.set({
    id: "TestEvent_" + event.params.id.toString(),
    value: event.params.contactDetails.name + ":" + event.params.contactDetails.email,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const owner = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("Simulate item defaults", () => {
  it("carries block numbers forward and increments log indexes", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            // No block: takes startBlock, logIndex 0.
            { contract: "Gravatar", event: "EmptyEvent" },
            // Still no block: same block, next logIndex.
            { contract: "Gravatar", event: "EmptyEvent" },
            { contract: "Gravatar", event: "EmptyEvent", block: { number: 50 } },
            // No block again: continues from the last explicit one.
            { contract: "Gravatar", event: "EmptyEvent" },
          ],
        },
      },
    });

    const entities = await indexer.SimulateTestEvent.getAll();
    entities.sort((a, b) => a.id.localeCompare(b.id));

    t.expect(entities).toEqual([
      { id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0 },
      { id: "1_1", blockNumber: 1, logIndex: 1, timestamp: 0 },
      { id: "50_2", blockNumber: 50, logIndex: 2, timestamp: 0 },
      { id: "50_3", blockNumber: 50, logIndex: 3, timestamp: 0 },
    ]);
  });

  it("passes an explicit block timestamp through to the event", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "EmptyEvent",
              block: { number: 5, timestamp: 1234567890 },
            },
          ],
        },
      },
    });

    t.expect(await indexer.SimulateTestEvent.get("5_0")).toEqual({
      id: "5_0",
      blockNumber: 5,
      logIndex: 0,
      timestamp: 1234567890,
    });
  });

  it("fills every param with a default when params are omitted", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [{ contract: "Gravatar", event: "NewGravatar" }],
        },
      },
    });

    t.expect(result.changes[0]?.Gravatar).toEqual({
      sets: [
        {
          id: "0",
          owner: "0x0000000000000000000000000000000000000000",
          displayName: "",
          imageUrl: "",
        },
      ],
    });
  });

  it("keeps the params given and defaults only the missing ones", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            { contract: "Gravatar", event: "NewGravatar", params: { id: 1n, owner } },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Gravatar).toEqual({
      sets: [{ id: "1", owner, displayName: "", imageUrl: "" }],
    });
  });

  it("delivers a named struct param as a record (#538)", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        137: {
          simulate: [
            {
              contract: "Gravatar",
              event: "TestEvent",
              params: {
                id: 42n,
                user: owner,
                contactDetails: { name: "Alice", email: "alice@example.com" },
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.SimpleEntity).toEqual({
      sets: [{ id: "TestEvent_42", value: "Alice:alice@example.com" }],
    });
  });

  it("processes chains in chain-id order regardless of key order", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        137: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: { id: 1n, owner, displayName: "Chain 137", imageUrl: "https://x/137.png" },
            },
          ],
        },
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [{ contract: "Noop", event: "EmptyEvent" }],
        },
      },
    });

    t.expect(result).toEqual({
      changes: [
        { block: 1, chainId: 1, eventsProcessed: 1 },
        {
          block: 1,
          chainId: 137,
          eventsProcessed: 1,
          Gravatar: {
            sets: [
              {
                id: "1",
                owner,
                displayName: "Chain 137",
                imageUrl: "https://x/137.png",
              },
            ],
          },
        },
      ],
    });
  });
});
`,
)
