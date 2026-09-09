open Vitest

// Covers the built onEvent registration: the handler-state fields
// (`handler`, `contractRegister`, `isWildcard`) registered via
// `indexer.onEvent` / `indexer.contractRegister` land on the built
// registration, and `dependsOnAddresses` follows the shared
// `Internal.dependsOnAddresses` formula. Filter-parsing behavior is
// covered separately by `EventFilters_test.res`.
let parsed = InternalTestIndexer.fromUserApi(
  ~registerHandlers=true,
  ~configYaml=`
name: on-event-registration
contracts:
  - name: NftFactory
    events:
      - event: SimpleNftCreated(string name, address contractAddress)
  - name: SimpleNft
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 tokenId)
  - name: EventFiltersTest
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: NftFactory
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
      - name: SimpleNft
      - name: EventFiltersTest
`,
  ~schema=`
type Token {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async ({ event, context }) => {
  context.Token.set({ id: event.params.tokenId.toString() });
});

indexer.contractRegister(
  { contract: "NftFactory", event: "SimpleNftCreated" },
  async ({ event, context }) => {
    context.chain.SimpleNft.add(event.params.contractAddress);
  },
);

// Wildcard with a \`where\` that filters on params rather than addresses, so
// \`filterByAddresses\` stays false and \`dependsOnAddresses\` follows from it.
indexer.onEvent(
  {
    contract: "EventFiltersTest",
    event: "Transfer",
    wildcard: true,
    where: { params: { from: "0x0000000000000000000000000000000000000000" } },
  },
  async ({ event, context }) => {
    context.Token.set({ id: event.params.amount.toString() });
  },
);
`,
)

let getEvmRegistration = (~contractName, ~eventName) => {
  let {HandlerRegister.onEventRegistrations: onEventRegistrations} =
    parsed.registrations()->Dict.getUnsafe("1")
  onEventRegistrations
  ->Array.find(registration =>
    registration.eventConfig.contractName === contractName &&
      registration.eventConfig.name === eventName
  )
  ->Option.getOrThrow
  ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration)
}

describe("onEventRegistration handler-state fields", () => {
  it("propagates handler from onEvent into the event config", t => {
    let registration = getEvmRegistration(~contractName="SimpleNft", ~eventName="Transfer")
    t.expect(registration.handler->Option.isSome).toBe(true)
  })

  it("propagates contractRegister from indexer.contractRegister", t => {
    let registration = getEvmRegistration(~contractName="NftFactory", ~eventName="SimpleNftCreated")
    t.expect(registration.contractRegister->Option.isSome).toBe(true)
  })

  it("marks wildcard: true registrations as isWildcard", t => {
    let registration = getEvmRegistration(~contractName="EventFiltersTest", ~eventName="Transfer")
    t.expect(registration.isWildcard).toBe(true)
  })

  it("computes dependsOnAddresses via Internal.dependsOnAddresses for the wildcard+where case", t => {
    let registration = getEvmRegistration(~contractName="EventFiltersTest", ~eventName="Transfer")
    t.expect((
      registration.dependsOnAddresses,
      registration.filterByAddresses,
    )).toEqual((
      Internal.dependsOnAddresses(
        ~isWildcard=registration.isWildcard,
        ~filterByAddresses=registration.filterByAddresses,
      ),
      false,
    ))
  })
})
