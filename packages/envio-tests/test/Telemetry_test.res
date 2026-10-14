open Vitest

// A heartbeat reports the features only the running indexer can see, read from
// what the project's handlers registered: config.yaml's own features are the
// CLI's to report.
let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: telemetry-features
contracts:
  - name: Factory
    events:
      - event: PairCreated(address indexed token0, address indexed token1, address pair)
  - name: Pair
    events:
      - event: Swap(address indexed sender, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Factory
        address: "0x1111111111111111111111111111111111111111"
      - name: Pair
`,
  ~schema=`
type Swap {
  id: ID!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const getPrice = createEffect(
  { name: "getPrice", input: S.string, output: S.number, rateLimit: false },
  async () => 1,
);

indexer.contractRegister(
  { contract: "Factory", event: "PairCreated" },
  async ({ event, context }) => {
    context.chain.Pair.add(event.params.pair);
  },
);

indexer.onEvent({ contract: "Pair", event: "Swap", wildcard: true }, async ({ context }) => {
  await context.effect(getPrice, "pair");
});

indexer.onBlock({ name: "everyBlock" }, async () => {});
`,
  ~registerHandlers=true,
)

describe("Telemetry runtime features", () => {
  it("names each feature the handlers use", t => {
    t.expect(
      Telemetry.runtimeFeatures(
        ~config=parsed.config,
        ~registrationsByChainId=Some(parsed.registrations()),
        ~splitRun=false,
      ),
    ).toEqual(["effects", "contract_register", "wildcard", "block_handlers"])
  })
})
