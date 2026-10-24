// An entity accessor a handler keeps and calls from work it didn't await must
// fail like `context.X` does once the handler has resolved, rather than write
// under whichever event happens to be running when the work fires.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: handler-context-after-resolve
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

const state = globalThis as unknown as { lateErrors: string[] };
state.lateErrors = [];

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  if (event.params.value === 1n) {
    const Account = context.Account;
    const isPreload = context.isPreload;
    setTimeout(() => {
      try {
        Account.set({ id: "late", balance: 1n });
      } catch (error) {
        if (!isPreload) state.lateErrors.push((error as Error).message);
      }
    }, 0);
  } else {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  context.Account.set({ id: event.params.to, balance: event.params.value });
});
`,
  ~test=`
import { it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const state = globalThis as unknown as { lateErrors: string[] };

it("rejects a kept entity accessor once its handler resolved", async (t) => {
  const indexer = createTestIndexer();
  const [from, first, second] = Addresses.mockAddresses;

  await indexer.process({
    chains: {
      1: {
        simulate: [
          { contract: "Token", event: "Transfer", params: { from, to: first, value: 1n } },
          { contract: "Token", event: "Transfer", params: { from, to: second, value: 2n } },
        ],
      },
    },
  });

  t.expect({
    lateErrors: state.lateErrors,
    late: await indexer.Account.get("late"),
    second: await indexer.Account.get(second),
  }).toEqual({
    lateErrors: [
      "Impossible to access context.Account after the handler is resolved. Make sure you didn't miss an await in the handler.",
    ],
    late: undefined,
    second: { id: second, balance: 2n },
  });
});
`,
)
