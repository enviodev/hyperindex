// `context.<Entity>` inside a handler: getOrCreate / getOrThrow, and the
// preload semantics that make a handler run twice per batch.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: handler-entity-load
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
enum AccountType {
  USER
  ADMIN
}

type User {
  id: ID!
  address: String!
  updatesCountOnUserForTesting: Int!
  gravatar: Gravatar
  accountType: AccountType!
}

type Gravatar {
  id: ID!
  displayName: String!
}

type LoaderRun {
  id: ID!
  isPreload: Boolean!
  sawEntityBeforeSet: Boolean!
  sawEntityAfterSet: Boolean!
}
`,
  ~handlers=`
import { indexer, type User, type LoaderRun } from "envio";

const newUser: User = {
  id: "0",
  address: "0x",
  updatesCountOnUserForTesting: 0,
  gravatar_id: undefined,
  accountType: "USER",
};

let getOrThrowInLoaderCount = 0;
const loaderRuns: LoaderRun[] = [];

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  switch (event.params.testCase) {
    // The first (preload) run's failures are swallowed so a batch isn't aborted
    // by an entity a sibling event was going to create. The second must abort.
    case "getOrThrow - ignores the first fail in loader": {
      if (getOrThrowInLoaderCount === 0) {
        getOrThrowInLoaderCount++;
        await context.User.getOrThrow("0", "Silently ignored on the first loader run");
      } else {
        await context.User.getOrThrow("0", "Second loader failure aborts processing");
      }
      return;
    }
    // A set during preload must not be visible to the preload run itself,
    // only to the run that actually writes.
    case "loaderSet": {
      const before = await context.User.get("0");
      context.User.set(newUser);
      const after = await context.User.get("0");
      // Recorded outside the store: a set from the preload run is exactly what
      // gets discarded, so the preload run cannot report itself as an entity.
      loaderRuns.push({
        id: String(loaderRuns.length),
        isPreload: context.isPreload,
        sawEntityBeforeSet: before !== undefined,
        sawEntityAfterSet: after !== undefined,
      });
      if (!context.isPreload) {
        loaderRuns.forEach((run) => context.LoaderRun.set(run));
      }
      return;
    }
  }

  if (context.isPreload) {
    return;
  }

  switch (event.params.testCase) {
    case "getOrCreate": {
      const user = await context.User.getOrCreate(newUser);
      context.Gravatar.set({ id: "seen", displayName: user.address });
      return;
    }
    case "getOrThrow": {
      const user = await context.User.getOrThrow("0");
      context.Gravatar.set({ id: "seen", displayName: user.address });
      return;
    }
    case "getOrThrow - custom message": {
      await context.User.getOrThrow("0", "User should always exist");
      return;
    }
    case "batch - 1": {
      context.Gravatar.set({ id: "1", displayName: "first" });
      return;
    }
    case "batch - 2": {
      context.Gravatar.set({ id: "2", displayName: "second" });
      return;
    }
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type User } from "envio";

const existingUser: User = {
  id: "0",
  address: "existing",
  updatesCountOnUserForTesting: 0,
  gravatar_id: undefined,
  accountType: "USER",
};

const run = (indexer: ReturnType<typeof createTestIndexer>, testCase: string) =>
  indexer.process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            contract: "Gravatar",
            event: "FactoryEvent",
            params: { contract: "0x1234567890123456789012345678901234567890", testCase },
          },
        ],
      },
    },
  });

describe("Handler entity loading", () => {
  it("getOrCreate creates the entity when it doesn't exist", async (t) => {
    const indexer = createTestIndexer();
    await run(indexer, "getOrCreate");

    t.expect(await indexer.User.getAll()).toEqual([
      {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      },
    ]);
  });

  it("getOrCreate loads the existing entity rather than overwriting it", async (t) => {
    const indexer = createTestIndexer();
    indexer.User.set(existingUser);
    await run(indexer, "getOrCreate");

    t.expect({
      users: await indexer.User.getAll(),
      seen: await indexer.Gravatar.get("seen"),
    }).toEqual({
      users: [existingUser],
      seen: { id: "seen", displayName: "existing" },
    });
  });

  it("getOrThrow returns the existing entity", async (t) => {
    const indexer = createTestIndexer();
    indexer.User.set(existingUser);
    await run(indexer, "getOrThrow");

    t.expect(await indexer.Gravatar.get("seen")).toEqual({
      id: "seen",
      displayName: "existing",
    });
  });

  it("getOrThrow rejects when the entity doesn't exist", async (t) => {
    const indexer = createTestIndexer();

    await t.expect(run(indexer, "getOrThrow")).rejects.toThrow();
  });

  it("getOrThrow rejects with the caller's custom message", async (t) => {
    const indexer = createTestIndexer();

    await t.expect(run(indexer, "getOrThrow - custom message")).rejects.toThrow(
      "User should always exist"
    );
  });

  it("getOrThrow ignores the first loader failure and aborts on the second", async (t) => {
    const indexer = createTestIndexer();

    await t.expect(
      run(indexer, "getOrThrow - ignores the first fail in loader")
    ).rejects.toThrow("Second loader failure aborts processing");
  });

  it("set during the preload run is invisible to that run", async (t) => {
    const indexer = createTestIndexer();
    await run(indexer, "loaderSet");

    t.expect(await indexer.LoaderRun.getAll()).toEqual([
      { id: "0", isPreload: true, sawEntityBeforeSet: false, sawEntityAfterSet: false },
      { id: "1", isPreload: false, sawEntityBeforeSet: false, sawEntityAfterSet: true },
    ]);
  });

  it("processes multiple events in one batch", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: "0x1234567890123456789012345678901234567890", testCase: "batch - 1" },
            },
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: "0x1234567890123456789012345678901234567890", testCase: "batch - 2" },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Gravatar.getAll()).toEqual([
      { id: "1", displayName: "first" },
      { id: "2", displayName: "second" },
    ]);
  });
});
`,
)
