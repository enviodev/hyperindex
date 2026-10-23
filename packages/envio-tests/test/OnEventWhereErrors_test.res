// A `where` the indexer can't honour fails the `indexer.onEvent` call that
// registered it, naming what's wrong and what to write instead. The calls run
// from a user test module, where registration is open, so each one fails on
// its own rather than taking the whole handlers module down. The values the
// generated types already reject are cast through, the way a JavaScript user
// would write them.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-event-where-errors
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Burn(address indexed from, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Noop {
  id: ID!
}
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

const errorOf = (where: unknown, event: "Transfer" | "Burn" = "Transfer") => {
  try {
    indexer.onEvent({ contract: "ERC20", event, where: where as any }, async () => {});
    return "no error";
  } catch (error) {
    return (error as Error).message;
  }
};

const onlyGte = (reason: string, path = "root") =>
  \`Invalid where configuration for ERC20. \\\`block\\\` filter is invalid: RescriptSchemaError: Failed parsing at \${path}. Reason: \${reason} Only \\\`_gte\\\` is supported on event filters — use \\\`indexer.onBlock\\\` for \\\`_lte\\\` or \\\`_every\\\`.\`;

describe("onEvent where errors", () => {
  it("names each block-range key an event filter doesn't take", (t) => {
    t.expect({
      lte: errorOf({ block: { number: { _gte: 10, _lte: 200 } } }),
      every: errorOf({ block: { number: { _gte: 10, _every: 5 } } }),
      gt: errorOf({ block: { number: { _gt: 10 } } }),
      numbre: errorOf({ block: { numbre: { _gte: 10 } } }),
    }).toEqual({
      lte: onlyGte('Encountered disallowed excess key "_lte" on an object.'),
      every: onlyGte('Encountered disallowed excess key "_every" on an object.'),
      gt: onlyGte('Encountered disallowed excess key "_gt" on an object.'),
      numbre: onlyGte('Encountered disallowed excess key "numbre" on an object.', '["block"]'),
    });
  });

  it("names a top-level key that is neither params nor block", (t) => {
    t.expect(errorOf({ blocks: { number: { _gte: 10 } } })).toBe(
      'Invalid where configuration. Unknown field "blocks". Indexed parameter filters must be nested under \\\`params\\\` and block-range filters under \\\`block\\\`',
    );
  });

  it("names a param the event doesn't index", (t) => {
    t.expect({
      missing: errorOf({ params: { from: ZERO, to: ZERO } }, "Burn"),
      notIndexed: errorOf({ params: { value: 1n } }, "Burn"),
    }).toEqual({
      missing:
        'Invalid where configuration. The event doesn\\'t have an indexed parameter "to" and can\\'t use it for filtering',
      notIndexed:
        'Invalid where configuration. The event doesn\\'t have an indexed parameter "value" and can\\'t use it for filtering',
    });
  });

  it("takes chain.<Contract>.addresses only as a param value, untransformed", (t) => {
    t.expect({
      spread: errorOf(({ chain }: any) => ({ params: { to: [...chain.ERC20.addresses] } })),
      unused: errorOf(({ chain }: any) => {
        const _addresses = chain.ERC20.addresses;
        return true;
      }),
    }).toEqual({
      spread:
        'Invalid where configuration for "ERC20": chain.ERC20.addresses must be passed directly as an indexed-param filter value (e.g. { params: { to: chain.ERC20.addresses } }). It cannot be spread, mapped, indexed, or otherwise transformed.',
      unused:
        "Invalid where configuration for ERC20. The callback reads \\\`chain.ERC20.addresses\\\` but doesn't use it as an indexed-param filter value. Use it directly, e.g. { params: { to: chain.ERC20.addresses } }.",
    });
  });
});
`,
)
