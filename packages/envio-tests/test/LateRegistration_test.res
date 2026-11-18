open Vitest

// A wildcard handler keeps a token's Transfer in the buffer before the factory
// registers the token. The token's own catch-up query fetches that log again:
// the buffer holds it once, so each handler runs on it once.

let factory = "0x2222222222222222222222222222222222222222"
let token = "0x4444444444444444444444444444444444444444"
let stranger = "0x5555555555555555555555555555555555555555"
let sender = "0x00000000000000000000000000000000000000aa"
let receiver = "0x00000000000000000000000000000000000000bb"

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let createdSighash = "0x1449abf21e49fd025f33495e77f7b1461caefdd3d4bb646424a3f445c4576a5b"

let transfer = (~blockNumber, ~address): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address,
  topics: [
    transferSighash,
    sender->ServedEvmChain.addressTopic,
    receiver->ServedEvmChain.addressTopic,
  ],
  data: 1n->ServedEvmChain.uintTopic,
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18703,
  ~rpcPort=18704,
  ~height=20,
  ~logs=[
    {
      blockNumber: 9,
      logIndex: 0,
      address: factory,
      topics: [createdSighash, token->ServedEvmChain.addressTopic],
    },
    transfer(~blockNumber=13, ~address=token),
    transfer(~blockNumber=14, ~address=stranger),
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: late-registration
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: Factory
    events:
      - event: Created(address indexed child)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[],
      ~contracts=`
      - name: Factory
        address: "${factory}"`,
    )}
`,
  ~schema=`
type Run {
  id: ID!
  count: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "Factory", event: "Created" }, async ({ event, context }) => {
  context.chain.Token.add(event.params.child);
});

const count = async (context: any, id: string) => {
  const run = await context.Run.get(id);
  context.Run.set({ id, count: (run?.count ?? 0) + 1 });
};

indexer.onEvent({ contract: "Token", event: "Transfer", wildcard: true }, async ({ event, context }) =>
  count(context, \`wildcard-\${event.block.number}\`),
);
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) =>
  count(context, \`byAddress-\${event.block.number}\`),
);
`,
)

type run = {id: string, count: int}

describe("A log stored before its address registers", () => {
  Async.it("reaches each handler once", async t =>
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let runs: array<run> = await indexer.query("Run")
        t.expect((
          served
          ->ServedEvmChain.takeHyperSyncQueries
          ->Array.map(({fromBlock, filters}) => (fromBlock, filters->Array.flatMap(f => f.address)))
          // The two first queries go out together, in either order.
          ->Array.toSorted(((a, x), (b, y)) =>
            a === b ? String.compare(x->Array.join(","), y->Array.join(",")) : Int.compare(a, b)
          ),
          runs->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        )).toEqual((
          // The address-free Transfer query holds the token's log at 13 before
          // the token's own query from its registration block reads it again.
          [(1, []), (1, [factory]), (9, [token])],
          [
            {id: "byAddress-13", count: 1},
            {id: "wildcard-13", count: 1},
            {id: "wildcard-14", count: 1},
          ],
        ))
      },
    )
  )
})
