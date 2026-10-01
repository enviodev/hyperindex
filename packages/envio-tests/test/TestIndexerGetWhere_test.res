// getWhere against linked-entity columns from a handler. Both cases are
// in-memory-only regressions: PgStorage queries the FK column directly, so
// neither reproduced against Postgres.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: get-where
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
type User {
  id: ID!
  address: String!
  gravatar: Gravatar
}

type Gravatar {
  id: ID!
  displayName: String!
}

type NftCollection {
  id: ID!
  name: String!
  tokens: [Token!]! @derivedFrom(field: "collection")
}

type Token {
  id: ID!
  tokenId: BigInt!
  collection: NftCollection!
  owner: User!
}

type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (context.isPreload) {
    return;
  }
  switch (event.params.testCase) {
    // https://github.com/enviodev/hyperindex/issues/1199 — filtering by the FK
    // db column (collection_id) of a relation whose logical name is
    // "collection". The in-memory store looked the field up by logical name and
    // threw "Field collection_id not found in entity Token".
    case "getWhereByLinkedEntityField": {
      const tokens = await context.Token.getWhere({
        collection_id: { _eq: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
      });
      context.Probe.set({ id: "issue-1199:" + tokens.length.toString() });
      return;
    }
    // getWhere on a nullable relation registers an in-memory index on that
    // column. A later set whose object simply omits the FK — the natural shape
    // for an unset nullable relation — used to crash updateIndices with
    // UndefinedKey("gravatar_id").
    case "getWhereThenSetNullableFk": {
      await context.User.getWhere({ gravatar_id: { _eq: "non-existent-gravatar" } });
      context.User.set({
        id: "user-with-null-gravatar",
        address: "0x1111111111111111111111111111111111111111",
        gravatar_id: undefined,
      });
      context.Probe.set({ id: "getWhereThenSetNullableFk:ok" });
      return;
    }
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Token } from "envio";

const collectionAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const otherCollectionAddress = "0xcccccccccccccccccccccccccccccccccccccccc";
const ownerAddress = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

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

describe("getWhere on linked-entity columns", () => {
  it("filters by the FK column of a named relation (#1199)", async (t) => {
    const indexer = createTestIndexer();
    const matching: Token = {
      id: collectionAddress + "-1",
      tokenId: 1n,
      collection_id: collectionAddress,
      owner_id: ownerAddress,
    };
    const other: Token = {
      id: otherCollectionAddress + "-1",
      tokenId: 2n,
      collection_id: otherCollectionAddress,
      owner_id: ownerAddress,
    };
    indexer.Token.set(matching);
    indexer.Token.set(other);

    const result = await run(indexer, "getWhereByLinkedEntityField");

    t.expect(result.changes[0]?.Probe).toEqual({ sets: [{ id: "issue-1199:1" }] });
  });

  it("survives a set that omits a nullable FK the query indexed", async (t) => {
    const indexer = createTestIndexer();

    const result = await run(indexer, "getWhereThenSetNullableFk");

    t.expect({ user: result.changes[0]?.User, probe: result.changes[0]?.Probe }).toEqual({
      user: {
        sets: [
          {
            id: "user-with-null-gravatar",
            address: "0x1111111111111111111111111111111111111111",
            gravatar_id: undefined,
          },
        ],
      },
      probe: { sets: [{ id: "getWhereThenSetNullableFk:ok" }] },
    });
  });
});
`,
)
