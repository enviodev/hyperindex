// A TTL drops an entity's rows whenever ClickHouse merges them, so for one kept
// in ClickHouse alone what a handler reads would change from one run to the
// next. Reading it is refused with what to do instead; writing it is not. One
// kept in Postgres too reads from there, which no TTL touches.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: clickhouse-ttl-read
storage:
  clickhouse: true
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "FactoryEvent(address indexed contract, string testCase)"
`,
  ~schema=`
type Expiring @storage(clickhouse: { ttl: "toDateTime(at) + INTERVAL 1 DAY" }) {
  id: ID!
  at: Timestamp!
}

type Kept @storage(postgres: true, clickhouse: { ttl: "toDateTime(at) + INTERVAL 1 DAY" }) {
  id: ID!
  at: Timestamp!
}

type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ context }) => {
  if (context.isPreload) {
    return;
  }
  const probe = async (read: () => Promise<{ id: string } | undefined>) => {
    try {
      context.Probe.set({ id: (await read())?.id ?? "missing" });
    } catch (error) {
      context.Probe.set({ id: (error as Error).message });
    }
  };
  context.Expiring.set({ id: "written", at: new Date(0) });
  context.Kept.set({ id: "kept", at: new Date(0) });
  await probe(() => context.Expiring.get("written"));
  await probe(() => context.Kept.get("kept"));
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("An entity with a ClickHouse TTL", () => {
  it("is written by handlers, and read by them only when Postgres keeps it too", async (t) => {
    const result = await createTestIndexer().process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: {
                contract: "0x1234567890123456789012345678901234567890",
                testCase: "read",
              },
            },
          ],
        },
      },
    });

    t.expect([result.changes[0]?.Probe, result.changes[0]?.Expiring?.sets?.length]).toEqual([
      {
        sets: [
          {
            id: "context.Expiring.get() is unavailable: Expiring is kept in ClickHouse alone with a ttl, which drops its rows whenever ClickHouse merges them, so a handler would read it differently from one run to the next. Keep it in Postgres too, with @storage(postgres: true, clickhouse: {...}), or drop the ttl.",
          },
          { id: "kept" },
        ],
      },
      1,
    ]);
  });
});
`,
)
