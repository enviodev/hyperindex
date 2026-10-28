open Vitest

// `indexer.onTransaction` from config.yaml and handler source to the rows
// written. Chain 1 fetches over HyperSync (server-side filter), chain 2 over
// RPC (every block read in full, filtered client-side); both serve the same
// transactions, so a filter a source gets wrong shows up as a wrong row.

let alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let bob = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
let token = "0x1111111111111111111111111111111111111111"
let other = "0x2222222222222222222222222222222222222222"

let transferSelector = "0xa9059cbb"
let approveSelector = "0x095ea7b3"
let transferInput =
  transferSelector ++
  ServedEvmChain.addressTopic(bob)->ServedEvmChain.dropPrefix ++
  ServedEvmChain.uintTopic(5n)->ServedEvmChain.dropPrefix
let oneEther = "0xde0b6b3a7640000"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18671,
  ~rpcPort=18672,
  ~height=6,
  ~logs=[
    // The transfer's own log, in the same transaction as block 1's transfer.
    {
      blockNumber: 1,
      logIndex: 0,
      address: token,
      topics: [
        transferSighash,
        alice->ServedEvmChain.addressTopic,
        bob->ServedEvmChain.addressTopic,
      ],
      data: ServedEvmChain.uintTopic(5n),
    },
  ],
  ~transactions=[
    {blockNumber: 1, transactionIndex: 0, from: alice, to: token, input: transferInput},
    // A plain send: no log on any contract the indexer knows.
    {blockNumber: 2, transactionIndex: 0, from: alice, to: other, value: oneEther},
    // Reverted, so it is mined but not successful.
    {blockNumber: 3, transactionIndex: 0, from: bob, to: token, input: transferInput, status: 0},
    {blockNumber: 4, transactionIndex: 0, from: bob, to: alice},
    {blockNumber: 5, transactionIndex: 0, from: other, to: token, input: approveSelector},
    // A contract creation has no recipient.
    {blockNumber: 6, transactionIndex: 0, from: bob, input: "0x6080"},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Token
        address: "${token}"`,
    )}
`,
  ~schema=`
type Seen {
  id: ID!
  from: String!
  to: String!
  hash: String!
  input: String!
  value: BigInt!
  status: Int!
  timestamp: Int!
}

type Transferred {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

const seenId = (chainId: number, block: number, transactionIndex: number, name: string) =>
  \`\${chainId}-\${block}-\${transactionIndex}-\${name}\`;

type Keys = {
  transaction: { transactionIndex: number; hash: string; from: string | undefined; to: string | undefined };
  block: { number: number; timestamp: number; hash: string };
  context: any;
};
const seen = ({ transaction, block, context }: Keys, name: string) =>
  context.Seen.set({
    id: seenId(context.chain.id, block.number, transaction.transactionIndex, name),
    from: (transaction.from ?? "none").toLowerCase(),
    to: (transaction.to ?? "none").toLowerCase(),
    hash: transaction.hash,
    input: "-",
    value: 0n,
    status: -1,
    timestamp: -1,
  });

indexer.onTransaction(
  {
    name: "from-alice",
    where: () => ({ transaction: { from: ["${alice}"] } }),
    fields: { transaction: ["input", "value", "status"], block: ["timestamp"] },
  },
  async ({ transaction, block, context }) => {
    context.Seen.set({
      id: seenId(context.chain.id, block.number, transaction.transactionIndex, "from-alice"),
      from: (transaction.from ?? "none").toLowerCase(),
      to: (transaction.to ?? "none").toLowerCase(),
      hash: transaction.hash,
      input: transaction.input,
      value: transaction.value,
      status: transaction.status ?? -1,
      timestamp: block.timestamp,
    });
  },
);

indexer.onTransaction(
  { name: "to-token", where: () => ({ transaction: { to: ["${token}"] } }) },
  async (args) => seen(args, "to-token"),
);

indexer.onTransaction(
  { name: "to-token-ok", where: () => ({ transaction: { to: ["${token}"], status: 1 } }) },
  async (args) => seen(args, "to-token-ok"),
);

indexer.onTransaction(
  { name: "transfers", where: () => ({ transaction: { sighash: ["${transferSelector}"] } }) },
  async (args) => seen(args, "transfers"),
);

// Every transaction of chain 1, and none of chain 2.
indexer.onTransaction(
  { name: "all", where: ({ chain }) => chain.id === 1 },
  async (args) => seen(args, "all"),
);

// Runs after the transaction handlers of its own transaction, so it sees what
// they wrote.
indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { transaction: ["transactionIndex"] } },
  async ({ event, context }) => {
  const afterTransaction = await context.Seen.get(
    seenId(event.chainId, event.block.number, event.transaction.transactionIndex, "from-alice"),
  );
  context.Transferred.set({
    id: \`\${event.chainId}-\${event.block.number}-\${afterTransaction ? "after" : "before"}-transaction\`,
  });
  },
);
`,
)

type seenRow = {
  id: string,
  from: string,
  to: string,
  hash: string,
  input: string,
  value: bigint,
  status: int,
  timestamp: int,
}

let readSeen = async (indexer: IndexerRunner.t) => {
  let rows: array<seenRow> = await indexer.query("Seen")
  rows->Array.toSorted((a, b) => String.compare(a.id, b.id))
}

type transferredRow = {id: string}

let readTransferred = async (indexer: IndexerRunner.t) => {
  let rows: array<transferredRow> = await indexer.query("Transferred")
  rows->Array.map(row => row.id)->ServedEvmChain.sorted
}

let hash = blockNumber => ServedEvmChain.transactionHashAt(~blockNumber, ~transactionIndex=0)

let keysOnly = (~chainId, ~blockNumber, ~from, ~to, name) => {
  id: `${chainId->Int.toString}-${blockNumber->Int.toString}-0-${name}`,
  from,
  to,
  hash: hash(blockNumber),
  input: "-",
  value: 0n,
  status: -1,
  timestamp: -1,
}

// Which handler saw which transaction, on both chains alike.
let expectedSeen = chainId => {
  let fromAlice = (blockNumber, ~to, ~input, ~value) => {
    id: `${chainId->Int.toString}-${blockNumber->Int.toString}-0-from-alice`,
    from: alice,
    to,
    hash: hash(blockNumber),
    input,
    value,
    status: 1,
    timestamp: blockNumber,
  }
  let keys = keysOnly(~chainId, ...)
  Array.concat(
    [
      fromAlice(1, ~to=token, ~input=transferInput, ~value=0n),
      fromAlice(2, ~to=other, ~input="0x", ~value=1000000000000000000n),
      keys(~blockNumber=1, ~from=alice, ~to=token, "to-token"),
      keys(~blockNumber=3, ~from=bob, ~to=token, "to-token"),
      keys(~blockNumber=5, ~from=other, ~to=token, "to-token"),
      keys(~blockNumber=1, ~from=alice, ~to=token, "to-token-ok"),
      keys(~blockNumber=5, ~from=other, ~to=token, "to-token-ok"),
      keys(~blockNumber=1, ~from=alice, ~to=token, "transfers"),
      keys(~blockNumber=3, ~from=bob, ~to=token, "transfers"),
    ],
    chainId === 1
      ? [
          keys(~blockNumber=1, ~from=alice, ~to=token, "all"),
          keys(~blockNumber=2, ~from=alice, ~to=other, "all"),
          keys(~blockNumber=3, ~from=bob, ~to=token, "all"),
          keys(~blockNumber=4, ~from=bob, ~to=alice, "all"),
          keys(~blockNumber=5, ~from=other, ~to=token, "all"),
          keys(~blockNumber=6, ~from=bob, ~to="none", "all"),
        ]
      : [],
  )
}

let key = filter => JSON.stringifyAny(filter)->Option.getOrThrow

let distinctTransactionFilters = (queries: array<ServedEvmChain.query>) => {
  let byKey = Dict.make()
  queries->Array.forEach(query =>
    query.transactionFilters->Array.forEach(filter => byKey->Dict.set(filter->key, filter))
  )
  byKey->Dict.valuesToArray->Array.toSorted((a, b) => String.compare(a->key, b->key))
}

// Every handler's filter goes to the server as its own selection, the
// unfiltered one as a selection with nothing in it.
let expectedTransactionFilters = distinctTransactionFilters([
  {
    fromBlock: 0,
    filters: [],
    transactionFilters: [
      {from: [alice], to: [], sighash: [], status: None},
      {from: [], to: [token], sighash: [], status: None},
      {from: [], to: [token], sighash: [], status: Some(1)},
      {from: [], to: [], sighash: [transferSelector], status: None},
      {from: [], to: [], sighash: [], status: None},
    ],
  },
])

// The RPC source reads every block in full, never a transaction by hash, and
// a receipt only where a filter or a selected field needs it.
let rpcReads = (requests: array<ServedEvmChain.rpcRequest>) => {
  let blocksInFull =
    requests
    ->Array.filterMap(request =>
      switch request {
      | {method: "eth_getBlockByNumber", params: [number, JSON.Boolean(true)]} =>
        Some(number->ServedEvmChain.quantity)
      | _ => None
      }
    )
    ->Array.toSorted(Int.compare)
  let receipts =
    requests
    ->Array.filterMap(request =>
      switch request {
      | {method: "eth_getTransactionReceipt", params: [JSON.String(hash)]} => Some(hash)
      | _ => None
      }
    )
    ->ServedEvmChain.sorted
  let byHash = requests->Array.filter(request => request.method === "eth_getTransactionByHash")
  (blocksInFull, receipts, byHash->Array.length)
}

describe("onTransaction", () => {
  Async.it(
    "runs each handler on the transactions its filter matches, over HyperSync and RPC alike",
    async t =>
      await served->ServedEvmChain.run(
        scenario,
        async indexer =>
          t.expect((
            await readSeen(indexer),
            await readTransferred(indexer),
            served->ServedEvmChain.takeHyperSyncQueries->distinctTransactionFilters,
            served->ServedEvmChain.rpcRequests->rpcReads,
            indexer.infoAndAboveLogs()->Array.filterMap(
              ({msg}) => msg->String.includes("runs on every transaction") ? Some(msg) : None,
            ),
          )).toEqual((
            Array.concat(expectedSeen(1), expectedSeen(2))->Array.toSorted(
              (a, b) => String.compare(a.id, b.id),
            ),
            ["1-1-after-transaction", "2-1-after-transaction"],
            expectedTransactionFilters,
            ([1, 2, 3, 4, 5, 6], [hash(1), hash(2), hash(3), hash(5)], 0),
            [
              "`indexer.onTransaction(\"all\")` runs on every transaction of chain 1: its `where` names no from, to or sighash filter.",
            ],
          )),
      ),
  )
})
