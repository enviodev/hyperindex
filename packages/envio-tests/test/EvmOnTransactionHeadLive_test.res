open Vitest

// Live test at the head of mainnet over HyperSync: starting at the latest
// block, a block handler marks every block processed and a transaction handler
// runs on the ERC-20 `transfer` calls to USDT in them; the rows for a few
// contiguous head blocks are compared with what a public RPC node holds.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live onTransaction head test",
  )

let usdt = "0xdAC17F958D2ee523a2206206994597C13D831ec7"

let scenario = Scenario.make(
  ~configYaml=`
name: evm-ontransaction-head-live
chains:
  - id: 1
    start_block: latest
`,
  ~schema=`
type Tick {
  id: ID!
}

type Call {
  id: ID!
  from: String!
  number: Int!
  transactionIndex: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock({ name: "ticks" }, async ({ block, context }) => {
  context.Tick.set({ id: \`\${block.number}\` });
});

indexer.onTransaction(
  { name: "usdt-transfers", where: () => ({ transaction: { to: ["${usdt}"], sighash: ["0xa9059cbb"] } }) },
  async ({ transaction, block, context }) => {
    context.Call.set({
      id: transaction.hash,
      from: (transaction.from ?? "none").toLowerCase(),
      number: block.number,
      transactionIndex: transaction.transactionIndex,
    });
  },
);
`,
)

type call = {id: string, from: string, number: int, transactionIndex: int}
type tick = {id: string}

// The node's own view of the calls in `[fromBlock, toBlock]`, read block by
// block in full. A null or an error from the load-balanced public node is
// asked again.
let groundTruth: (int, int, string) => promise<array<call>> = %raw(`
  async (fromBlock, toBlock, usdt) => {
    const rpc = async (method, params) => {
      for (let attempt = 0; ; attempt++) {
        try {
          const response = await fetch("https://ethereum-rpc.publicnode.com", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
          });
          const body = await response.json();
          if (body.error) throw new Error(JSON.stringify(body.error));
          if (body.result !== null) return body.result;
          throw new Error("null result for " + method);
        } catch (error) {
          if (attempt >= 8) throw error;
          await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
        }
      }
    };
    const calls = [];
    for (let n = fromBlock; n <= toBlock; n++) {
      const block = await rpc("eth_getBlockByNumber", ["0x" + n.toString(16), true]);
      for (const tx of block.transactions) {
        if (tx.to && tx.to.toLowerCase() === usdt.toLowerCase() && tx.input.startsWith("0xa9059cbb")) {
          calls.push({ id: tx.hash, from: tx.from.toLowerCase(), number: n, transactionIndex: Number(tx.transactionIndex) });
        }
      }
    }
    return calls;
  }
`)

let byId = (a: call, b: call) => String.compare(a.id, b.id)

describe("onTransaction at the head of mainnet", () => {
  Async.it(
    "runs on the calls of every block it processes while following the chain",
    ~timeout=240_000,
    async t => {
      let processed = ref([])
      await scenario->Scenario.run(
        ~yamlSources=true,
        async (~indexer, ~source as _) => {
          // Three head blocks, so at least one arrived while following.
          let deadline = Date.now() +. 180_000.
          let ticks = ref([])
          while ticks.contents->Array.length < 3 && Date.now() < deadline {
            await Utils.delay(1000)
            ticks := (await indexer.query("Tick"))
          }
          let numbers =
            ticks.contents
            ->Array.filterMap((tick: tick) => tick.id->Int.fromString)
            ->Array.toSorted(Int.compare)
          let calls: array<call> = await indexer.query("Call")
          processed := [(numbers, calls)]
        },
      )
      let (numbers, calls) = processed.contents->Array.getUnsafe(0)
      let fromBlock = numbers->Array.getUnsafe(0)
      let toBlock = numbers->Array.getUnsafe(numbers->Array.length - 1)
      let expected = await groundTruth(fromBlock, toBlock, usdt)
      t.expect((
        numbers->Array.length >= 3,
        toBlock - fromBlock + 1 === numbers->Array.length,
        expected->Array.length > 0,
        calls
        ->Array.filter(call => call.number >= fromBlock && call.number <= toBlock)
        ->Array.toSorted(byId),
      )).toEqual((true, true, true, expected->Array.toSorted(byId)))
    },
  )
})
