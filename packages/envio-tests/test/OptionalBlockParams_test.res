// Block-range resolution for `process()`: which defaults apply when startBlock
// or endBlock are omitted, how progress carries into a second call, and what
// invalid ranges report. Migrated from scenarios/test_codegen.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: block-params
contracts:
  - name: Gravatar
    events:
      - event: EmptyEvent()
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type SimulateTestEvent {
  id: ID!
  blockNumber: Int!
  logIndex: Int!
  timestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "EmptyEvent" }, async ({ event, context }) => {
  context.SimulateTestEvent.set({
    id: \`\${event.block.number}_\${event.logIndex}\`,
    blockNumber: event.block.number,
    logIndex: event.logIndex,
    timestamp: event.block.timestamp,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type SimulateTestEvent } from "envio";

const emptyEvent = { contract: "Gravatar", event: "EmptyEvent" } as const;

const at = (blockNumber: number): SimulateTestEvent => ({
  id: \`\${blockNumber}_0\`,
  blockNumber,
  logIndex: 0,
  timestamp: 0,
});

const messageOf = async (run: () => Promise<unknown>): Promise<string | undefined> => {
  try {
    await run();
    return undefined;
  } catch (error) {
    return (error as Error).message;
  }
};

describe("optional block params", () => {
  it("defaults startBlock from config and endBlock to startBlock", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [emptyEvent] } } });

    t.expect(await indexer.SimulateTestEvent.getAll()).toEqual([at(1)]);
  });

  it("defaults endBlock to startBlock when only startBlock is given", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 5, simulate: [emptyEvent] } } });

    t.expect(await indexer.SimulateTestEvent.getAll()).toEqual([at(5)]);
  });

  it("uses explicit startBlock and endBlock when provided", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100, simulate: [emptyEvent] } } });

    t.expect(await indexer.SimulateTestEvent.getAll()).toEqual([at(1)]);
  });

  it("defaults startBlock to progressBlock+1 on a second process call", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100, simulate: [emptyEvent] } } });
    // Omitting startBlock resumes at 101.
    await indexer.process({ chains: { 1: { simulate: [{ ...emptyEvent, block: { number: 101 } }] } } });

    const entities = await indexer.SimulateTestEvent.getAll();
    const byBlock = [...entities].sort((a, b) => a.blockNumber - b.blockNumber);
    t.expect(byBlock).toEqual([at(1), at(101)]);
  });

  it("defaults endBlock to the highest simulate block number", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [{ ...emptyEvent, block: { number: 50 } }] } } });

    t.expect(await indexer.SimulateTestEvent.getAll()).toEqual([at(50)]);
  });

  // The generated types reject the next three inputs outright, so each casts
  // through \`any\` to reach the runtime validation behind them.
  it("rejects a non-numeric chain ID", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { abc: { startBlock: 1, endBlock: 100 } } } as any),
    );

    t.expect(message).toBe('Invalid chain ID "abc": expected a numeric chain ID');
  });

  it("rejects a chain ID absent from the config", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 9999: { startBlock: 1, endBlock: 100 } } } as any),
    );

    t.expect(message).toBe("Chain 9999 is not configured in config.yaml");
  });

  it("rejects a startBlock of the wrong type", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 1: { startBlock: "not_a_number" } } } as any),
    );

    t.expect(message).toBe(
      'Invalid processConfig: RescriptSchemaError: Failed parsing at ["chains"]["1"]["startBlock"]. ' +
        'Reason: Expected int32 | undefined, received "not_a_number"',
    );
  });

  // Without simulate items and without an endBlock the run enters auto-exit
  // mode. It has no real source to read from, so race a timeout and assert only
  // that block-range validation didn't reject it.
  it("enters auto-exit mode when endBlock is omitted without simulate", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      Promise.race([
        indexer.process({ chains: { 1: { startBlock: 1 } } }),
        new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 3000)),
      ]),
    );

    t.expect(message === undefined || !message.includes("endBlock is required")).toBe(true);
  });
});
`,
)
