// An anonymous event's logs carry no signature topic: topic0 holds the first
// indexed param. The indexer can only select those logs by naming that param's
// values, so a registration that doesn't, in any alternative, fails the
// `indexer.onEvent` call that made it. The values the generated types already
// reject are cast through, the way a JavaScript user would write them.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: anonymous-event-where-errors
contracts:
  - name: Vat
    events:
      - event: LogNote(bytes4 indexed sig, address indexed guy, bytes32 indexed foo, bytes32 indexed bar, uint256 wad, bytes fax) anonymous
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Vat
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

const SIG = "0x29ae8114";
const GUY = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

const errorOf = (options: object) => {
  try {
    indexer.onEvent({ contract: "Vat", event: "LogNote", ...options } as any, async () => {});
    return "no error";
  } catch (error) {
    return (error as Error).message;
  }
};

const whereError =
  'Invalid where configuration for the anonymous event "LogNote" on contract "Vat". An anonymous event has no signature topic to select its logs by, so every \`where\` filter must name values for its first indexed parameter "sig", e.g. { params: { sig: [...] } }.';

describe("anonymous event where errors", () => {
  it("requires every filter to name values for the first indexed param", (t) => {
    t.expect({
      missing: errorOf({}),
      keepAll: errorOf({ where: true }),
      keepAllCallback: errorOf({ where: () => true }),
      empty: errorOf({ where: {} }),
      emptyParams: errorOf({ where: { params: {} } }),
      emptyParamsList: errorOf({ where: { params: [] } }),
      blockOnly: errorOf({ where: { block: { number: { _gte: 10 } } } }),
      otherParamOnly: errorOf({ where: { params: { guy: GUY } } }),
      alternativeWithoutSig: errorOf({ where: { params: [{ sig: SIG }, { guy: GUY }] } }),
      noSigValues: errorOf({ where: { params: { sig: [] } } }),
      contractAddresses: errorOf({ where: ({ chain }: any) => ({ params: { sig: chain.Vat.addresses } }) }),
      skip: errorOf({ where: false }),
      skipCallback: errorOf({ where: () => false }),
      sig: errorOf({ where: { params: { sig: SIG } } }),
      everyAlternative: errorOf({ where: { params: [{ sig: SIG }, { sig: [SIG], guy: GUY }] } }),
    }).toEqual({
      missing: whereError,
      keepAll: whereError,
      keepAllCallback: whereError,
      empty: whereError,
      emptyParams: whereError,
      emptyParamsList: whereError,
      blockOnly: whereError,
      otherParamOnly: whereError,
      alternativeWithoutSig: whereError,
      noSigValues: whereError,
      contractAddresses: whereError,
      skip: "no error",
      skipCallback: "no error",
      sig: "no error",
      everyAlternative: "no error",
    });
  });
});
`,
)
