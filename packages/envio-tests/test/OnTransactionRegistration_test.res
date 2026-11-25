// A transaction filter the indexer can't honour fails the
// `indexer.onTransaction` call that registered it, naming what's wrong. The
// calls run from a user test module, where registration is open. Values the
// generated types already reject are cast through, the way a JavaScript user
// would write them.

let errorTests = `
import { describe, it } from "vitest";
import { indexer } from "envio";

const errorOf = (where: unknown) => {
  try {
    indexer.onTransaction({ name: "bad", where: where as any }, async () => {});
    return "no error";
  } catch (error) {
    return (error as Error).message;
  }
};

const invalid = (message: string) =>
  \`\\\`indexer.onTransaction("bad")\\\` \\\`where\\\` returned an invalid filter for chain 1: \${message}\`;

describe("onTransaction registration errors", () => {
  it("names a value that can't be matched", (t) => {
    t.expect({
      shortAddress: errorOf(() => ({ transaction: { from: ["0x1234"] } })),
      notAList: errorOf(() => ({ transaction: { to: "0x1111111111111111111111111111111111111111" } })),
      emptyList: errorOf(() => ({ transaction: { to: [] } })),
      statusNotAList: errorOf(() => ({ transaction: { status: 1 } })),
      unknownStatus: errorOf(() => ({ transaction: { status: [2] } })),
      noStatus: errorOf(() => ({ transaction: { status: [] } })),
    }).toEqual({
      shortAddress: invalid('\\\`from\\\` value "0x1234" is not a 20-byte hex address.'),
      notAList: invalid("\\\`to\\\` must be an array of 20-byte hex addresses."),
      emptyList: invalid("\\\`to\\\` lists no value, so it would match no transaction."),
      statusNotAList: invalid("\\\`status\\\` must be an array of 0 (reverted) and 1 (succeeded)."),
      unknownStatus: invalid("\\\`status\\\` value 2 is not 0 (reverted) or 1 (succeeded)."),
      noStatus: invalid("\\\`status\\\` lists no value, so it would match no transaction."),
    });
  });

  it("names a filter of the wrong shape", (t) => {
    const shape = "Expected \\\`true\\\`, \\\`false\\\` or { transaction: { from?, to?, status? } }.";
    t.expect({
      outer: errorOf(() => ({ from: ["0x1111111111111111111111111111111111111111"] })),
      inner: errorOf(() => ({ transaction: { value: [1n] } })),
      returned: errorOf(() => undefined),
      notAFunction: errorOf({ transaction: {} }),
    }).toEqual({
      outer: invalid(shape),
      inner: invalid(\`Unknown field \\\`value\\\`. \${shape}\`),
      returned:
        '\\\`indexer.onTransaction("bad")\\\` \\\`where\\\` returned an invalid value of type undefined. Expected \\\`true\\\`, \\\`false\\\` or a filter object.',
      notAFunction:
        '\\\`indexer.onTransaction("bad")\\\` expected \\\`where\\\` to be a function returning the filter for a chain, but got object.',
    });
  });

  it("names a missing name or handler at the call that registered it", (t) => {
    const errorOfCall = (name: unknown, handler: unknown) => {
      try {
        indexer.onTransaction({ name: name as any, where: () => true }, handler as any);
        return "no error";
      } catch (error) {
        return (error as Error).message;
      }
    };
    t.expect({
      noName: errorOfCall(undefined, async () => {}),
      emptyName: errorOfCall("", async () => {}),
      noHandler: errorOfCall("bad", undefined),
    }).toEqual({
      noName: "\\\`indexer.onTransaction\\\` expected \\\`name\\\` to be a non-empty string, but got undefined.",
      emptyName: "\\\`indexer.onTransaction\\\` expected \\\`name\\\` to be a non-empty string, but got string.",
      noHandler:
        '\\\`indexer.onTransaction("bad")\\\` expected a handler function as the second argument, but got undefined.',
    });
  });

  it("hands \\\`where\\\` each contract's name and abi", (t) => {
    let seen: unknown;
    indexer.onTransaction(
      {
        name: "reads-abi",
        where: ({ chain }) => {
          seen = [chain.Token.name, chain.Token.abi.length > 0];
          return false;
        },
      },
      async () => {},
    );
    t.expect(seen).toEqual(["Token", true]);
  });

  it("refuses a contract's addresses, which a static filter can't follow", (t) => {
    t.expect(errorOf(({ chain }: any) => ({ transaction: { to: chain.Token.addresses } }))).toBe(
      '\\\`indexer.onTransaction("bad")\\\` filters on static values, so \\\`chain.Token.addresses\\\` can\\'t be used: contracts registered while indexing would never reach the filter. List the addresses instead.',
    );
  });
});
`

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-registration
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Noop {
  id: ID!
}
`,
  // A handler reads \`block.number\` and what it lists, as an event handler
  // does.
  ~handlers=`
import {
  indexer,
  type EvmOnTransactionContext,
  type EvmOnTransactionHandler,
  type EvmOnTransactionOptions,
  type EvmOnTransactionWhere,
  type EvmOnTransactionWhereFilter,
} from "envio";

// The exported types are named as onEvent's are.
const fields = { transaction: ["hash"] } as const;
const filter: EvmOnTransactionWhereFilter = { transaction: { status: [0, 1] } };
const where: EvmOnTransactionWhere = ({ chain }) => chain.id === 1 && filter;
const options: EvmOnTransactionOptions<typeof fields> = { name: "exported", where, fields };
const handler: EvmOnTransactionHandler<typeof fields> = async ({ transaction, context }) => {
  const sameContext: EvmOnTransactionContext = context;
  void transaction.hash, sameContext;
};
indexer.onTransaction(options, handler);
// @ts-expect-error - the context isn't a parameter
type WithContext = EvmOnTransactionHandler<typeof fields, EvmOnTransactionContext>;

indexer.onTransaction(
  {
    name: "typed",
    where: () => ({ transaction: { from: ["0x1111111111111111111111111111111111111111"], status: [1] } }),
    fields: { transaction: ["value"], block: ["miner"] },
  },
  async ({ transaction }) => {
    const always: number = transaction.block.number;
    const listed: [bigint, string] = [transaction.value, transaction.block.miner];
    // @ts-expect-error - transactionIndex is not listed
    const transactionIndex: number = transaction.transactionIndex;
    // @ts-expect-error - hash is not listed
    const hash: string = transaction.hash;
    // @ts-expect-error - from is filtered on but not listed
    const from: string = transaction.from;
    // @ts-expect-error - timestamp is not listed
    const timestamp: number = transaction.block.timestamp;
    void always, listed, transactionIndex, hash, from, timestamp;
  },
);

// Never called: these only have to fail type-checking.
export const registerWithAddresses = () =>
  indexer.onTransaction(
    // @ts-expect-error - a filter's values are static
    { name: "addresses", where: ({ chain }) => ({ transaction: { to: chain.Token.addresses } }) },
    async () => {},
  );
export const registerWithOneStatus = () =>
  indexer.onTransaction(
    // @ts-expect-error - \`status\` lists the outcomes to run on
    { name: "one-status", where: () => ({ transaction: { status: 1 } }) },
    async () => {},
  );
export const registerWithBlockArgument = () =>
  indexer.onTransaction(
    { name: "block-argument", where: () => true },
    // @ts-expect-error - the block is \`transaction.block\`
    async ({ block }) => block,
  );
export const registerWithoutWhere = () =>
  // @ts-expect-error - a transaction handler needs a \`where\`
  indexer.onTransaction({ name: "no-where" }, async () => {});
`,
  ~test=errorTests,
)
