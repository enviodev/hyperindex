// https://github.com/enviodev/hyperindex/issues/1678
// Contract import maps a tuple param to a Json field. The decoded value holds
// bigints, which no storage can write as JSON, so assigning it as is must not
// type-check. The handlers below are what contract import generates for these
// events (see the `json_bigint_events` snapshots in `contract_import_templates.rs`).
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: json-bigint
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: WXTZ
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: EnforcedOptionSet((uint32,uint16,bytes)[] _enforcedOptions)
          - event: PeerSet((address peer, string label) info)
          - event: BatchSent((uint256 amount, (uint64 at, bool done)[] steps)[] items, uint256 total)
`,
  ~schema=`
type WXTZ_EnforcedOptionSet {
  id: ID!
  _enforcedOptions: Json!
}

type WXTZ_PeerSet {
  id: ID!
  info: Json!
}

type WXTZ_BatchSent {
  id: ID!
  items: Json!
  total: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";
import type {
  WXTZ_EnforcedOptionSet,
  WXTZ_PeerSet,
  WXTZ_BatchSent,
} from "envio";

indexer.onEvent({ contract: "WXTZ", event: "EnforcedOptionSet" }, async ({ event, context }) => {
  const entity: WXTZ_EnforcedOptionSet = {
    id: \`\${event.chainId}_\${event.block.number}_\${event.logIndex}\`,
    _enforcedOptions: event.params._enforcedOptions.map((item) => ({
      0: item[0].toString(),
      1: item[1].toString(),
      2: item[2],
    })),
  };

  context.WXTZ_EnforcedOptionSet.set(entity);
});

indexer.onEvent({ contract: "WXTZ", event: "PeerSet" }, async ({ event, context }) => {
  const entity: WXTZ_PeerSet = {
    id: \`\${event.chainId}_\${event.block.number}_\${event.logIndex}\`,
    info: event.params.info,
  };

  context.WXTZ_PeerSet.set(entity);
});

indexer.onEvent({ contract: "WXTZ", event: "BatchSent" }, async ({ event, context }) => {
  const entity: WXTZ_BatchSent = {
    id: \`\${event.chainId}_\${event.block.number}_\${event.logIndex}\`,
    items: event.params.items.map((item) => ({
      amount: item.amount.toString(),
      steps: item.steps.map((item1) => ({
        at: item1.at.toString(),
        done: item1.done,
      })),
    })),
    total: event.params.total,
  };

  context.WXTZ_BatchSent.set(entity);
});

indexer.onEvent({ contract: "WXTZ", event: "EnforcedOptionSet" }, async ({ event, context }) => {
  context.WXTZ_EnforcedOptionSet.set({
    id: "unconverted",
    // @ts-expect-error a bigint is not JSON
    _enforcedOptions: event.params._enforcedOptions,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import {
  createTestIndexer,
  TestHelpers,
  type WXTZ_EnforcedOptionSet,
  type WXTZ_PeerSet,
  type WXTZ_BatchSent,
} from "envio";

const maxUint256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935n;
const peer = TestHelpers.Addresses.defaultAddress;

describe("Json fields from tuple params", () => {
  it("store bigints as decimal strings", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "WXTZ",
              event: "EnforcedOptionSet",
              params: {
                _enforcedOptions: [
                  { 0: 30101n, 1: 1n, 2: "0x0003" },
                  { 0: 30110n, 1: maxUint256, 2: "0x" },
                ],
              },
            },
            {
              contract: "WXTZ",
              event: "PeerSet",
              params: { info: { peer, label: "bridge" } },
            },
            {
              contract: "WXTZ",
              event: "BatchSent",
              params: {
                items: [{ amount: 5n, steps: [{ at: 7n, done: true }] }],
                total: 5n,
              },
            },
          ],
        },
      },
    });

    const expected: [WXTZ_EnforcedOptionSet, WXTZ_PeerSet, WXTZ_BatchSent] = [
      {
        id: "1_0_0",
        _enforcedOptions: [
          { 0: "30101", 1: "1", 2: "0x0003" },
          { 0: "30110", 1: maxUint256.toString(), 2: "0x" },
        ],
      },
      { id: "1_0_1", info: { peer, label: "bridge" } },
      { id: "1_0_2", items: [{ amount: "5", steps: [{ at: "7", done: true }] }], total: 5n },
    ];
    t.expect([
      await indexer.WXTZ_EnforcedOptionSet.getOrThrow("1_0_0"),
      await indexer.WXTZ_PeerSet.getOrThrow("1_0_1"),
      await indexer.WXTZ_BatchSent.getOrThrow("1_0_2"),
    ]).toEqual(expected);
  });
});
`,
)
