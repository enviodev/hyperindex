open Vitest

// What each source asks its server for to run transaction handlers. HyperSync
// filters on the server: one transaction selection per distinct filter, and
// only the fields the handlers read and the filters compare. RPC has no
// transaction filter: it reads every block of a page in full, at most 100 of
// them, and a receipt only for a transaction whose call already matched a
// filter that needs one. Chain 1 fetches over HyperSync and chain 2 over RPC.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let carol = "0x3333333333333333333333333333333333333333"
let dave = "0x4444444444444444444444444444444444444444"

let height = 250

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18765,
  ~rpcPort=18766,
  ~height,
  ~logs=[],
  ~transactions=[
    {blockNumber: 1, transactionIndex: 0, from: alice, to: bob, value: 7n},
    {blockNumber: 2, transactionIndex: 0, from: bob, to: alice, status: 0, gasUsed: 30000n},
    {blockNumber: 3, transactionIndex: 0, from: carol, to: alice},
    {blockNumber: 150, transactionIndex: 0, from: dave, to: bob},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-wire
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Token
        address: "${carol}"`,
      ~rpcOptions=`
      initial_block_interval: 1000
      interval_ceiling: 1000`,
    )}
`,
  ~schema=`
type Run {
  id: ID!
  value: String
  gasUsed: String
}
`,
  ~handlers=`
import { indexer } from "envio";

const id = (context: { chain: { id: number } }, name: string, block: { number: number }) =>
  \`\${context.chain.id}-\${block.number}-\${name}\`;

indexer.onTransaction(
  {
    name: "alice-to-bob",
    where: () => ({ transaction: { from: ["${alice}"], to: ["${bob}"] } }),
    fields: { transaction: ["value"] },
  },
  async ({ transaction, context }) =>
    context.Run.set({ id: id(context, "alice-to-bob", transaction.block), value: transaction.value.toString(), gasUsed: undefined }),
);
indexer.onTransaction(
  {
    name: "alice-to-bob-again",
    where: () => ({ transaction: { from: ["${alice}"], to: ["${bob}"] } }),
  },
  async ({ transaction, context }) =>
    context.Run.set({ id: id(context, "alice-to-bob-again", transaction.block), value: undefined, gasUsed: undefined }),
);
indexer.onTransaction(
  {
    name: "reverted-to-alice",
    where: () => ({ transaction: { to: ["${alice}"], status: [0] } }),
    fields: { transaction: ["gasUsed"] },
  },
  async ({ transaction, context }) =>
    context.Run.set({ id: id(context, "reverted-to-alice", transaction.block), value: undefined, gasUsed: transaction.gasUsed.toString() }),
);
`,
)

type run = {id: string, value: option<string>, gasUsed: option<string>}

let strings = json =>
  json
  ->JSON.Decode.array
  ->Option.getOr([])
  ->Array.filterMap(JSON.Decode.string)
  ->Array.toSorted(String.compare)

type hyperSyncQuery = {
  transactions: JSON.t,
  transactionFields: array<string>,
  blockFields: array<string>,
}

type rpcRequest = {method: string, params: array<JSON.t>}

describe("onTransaction wire", () => {
  Async.it("asks each source for exactly what the handlers need", async t => {
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let runs: array<run> = await indexer.query("Run")
        let hyperSyncQueries =
          (served->ServedEvmChain.servers).hyperSync
          ->MockHyperSyncServer.takeQueries
          ->Array.filterMap(
            query => {
              let query = query->JSON.Decode.object->Option.getOrThrow
              query
              ->Dict.get("transactions")
              ->Option.map(
                transactions => {
                  let fields =
                    query->Dict.getUnsafe("field_selection")->JSON.Decode.object->Option.getOrThrow
                  {
                    transactions,
                    transactionFields: fields->Dict.get("transaction")->Option.mapOr([], strings),
                    blockFields: fields->Dict.get("block")->Option.mapOr([], strings),
                  }
                },
              )
            },
          )
        let rpcRequests = (served->ServedEvmChain.servers).rpc.requests->Array.map(
          body => {
            let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
            {
              method: request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow,
              params: request->Dict.getUnsafe("params")->JSON.Decode.array->Option.getOrThrow,
            }
          },
        )
        let reads = (~method, ~fullBlock=?) =>
          rpcRequests
          ->Array.filter(
            request =>
              request.method === method &&
                switch fullBlock {
                | Some(full) => request.params->Array.getUnsafe(1) == JSON.Boolean(full)
                | None => true
                },
          )
          ->Array.map(request => request.params->Array.getUnsafe(0))
        let rpcPages =
          indexer.allLogsAsJson()
          ->Array.filter(
            line =>
              line->Dict.get("msg") == Some(JSON.String("Finished querying")) &&
                line->Dict.get("chainId") == Some(JSON.Number(2.)),
          )
          ->Array.map(
            line => (
              line->Dict.getUnsafe("fromBlock")->JSON.Decode.float->Option.getOrThrow->Float.toInt,
              line->Dict.getUnsafe("toBlock")->JSON.Decode.float->Option.getOrThrow->Float.toInt,
            ),
          )
          ->Array.toSorted(((a, _), (b, _)) => Int.compare(a, b))
        let distinctHyperSyncQueries = {
          let byKey = Dict.make()
          hyperSyncQueries->Array.forEach(
            query => byKey->Dict.set(query->JSON.stringifyAny->Option.getOrThrow, query),
          )
          byKey->Dict.valuesToArray
        }
        let hash = (~blockNumber) => JSON.String(
          ServedEvmChain.transactionHashAt(~blockNumber, ~transactionIndex=0),
        )

        t.expect((
          runs->Array.toSorted((a, b) => String.compare(a.id, b.id)),
          distinctHyperSyncQueries,
          reads(~method="eth_getBlockByNumber", ~fullBlock=true)->Array.length,
          reads(~method="eth_getBlockByNumber", ~fullBlock=false),
          reads(~method="eth_getTransactionReceipt")->Array.toSorted(
            (a, b) => String.compare(a->JSON.stringify, b->JSON.stringify),
          ),
          reads(~method="eth_getTransactionByHash"),
          (
            rpcPages->Array.reduce(
              0,
              (widest, (from, to)) => Pervasives.max(widest, to - from + 1),
            ),
            rpcPages->Array.everyWithIndex(
              ((from, _), index) =>
                from == (index == 0 ? 1 : Pair.second(rpcPages->Array.getUnsafe(index - 1)) + 1),
            ),
            rpcPages->Array.at(-1)->Option.map(Pair.second),
          ),
        )).toEqual((
          [1, 2]
          ->Array.flatMap(
            chainId => [
              {
                id: `${chainId->Int.toString}-1-alice-to-bob`,
                value: Some("7"),
                gasUsed: None,
              },
              {
                id: `${chainId->Int.toString}-1-alice-to-bob-again`,
                value: None,
                gasUsed: None,
              },
              {
                id: `${chainId->Int.toString}-2-reverted-to-alice`,
                value: None,
                gasUsed: Some("30000"),
              },
            ],
          )
          ->Array.toSorted((a, b) => String.compare(a.id, b.id)),
          [
            {
              transactions: JSON.parseOrThrow(
                `[{"from":["${alice}"],"to":["${bob}"],"status":1},{"to":["${alice}"],"status":0}]`,
              ),
              transactionFields: [
                "block_number",
                "from",
                "gas_used",
                "hash",
                "status",
                "to",
                "transaction_index",
                "value",
              ],
              blockFields: ["hash", "number", "timestamp"],
            },
          ],
          height,
          [],
          [hash(~blockNumber=1), hash(~blockNumber=2), hash(~blockNumber=3)],
          [],
          (100, true, Some(height)),
        ))
      },
    )
  })
})
