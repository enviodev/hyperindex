open Vitest

// `indexer.onEvent` `where` param filters, from a user's config.yaml and
// handler source to the rows the indexer writes. Chains 1 and 2 fetch over
// HyperSync and chains 3 and 4 over RPC, all from the same served logs, which
// hold a matching and a non-matching log for every filter. Both servers return
// only what the query's filter matches, so a filter a source fails to send, or
// sends wrong, is a row that shouldn't be there or a row that's missing.

let indexedAddress = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
let wildcardEmitter = "0x3333333333333333333333333333333333333333"
let zero = "0x0000000000000000000000000000000000000000"
let zeroWord = ServedEvmChain.word("")

// What Solidity puts in topic1 for each value a filter below names.
type indexedCase = {event: string, sighash: string, matching: array<string>}

let indexedCases = [
  {
    event: "IndexedUint",
    sighash: "0x19bb82bd7a02b03fa3da5dc3a20f5592ca2de05229701d258d7c6bd1e4f7a85f",
    matching: [
      "0x0000000000000000000000000000000000000000000000000000000000000032",
      "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ],
  },
  {
    event: "IndexedInt",
    sighash: "0xa8d876f488d1e440021398f5ab42c36a51b45e5f6e29d212668c39935dce1bce",
    matching: [
      "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffce",
      "0x8000000000000000000000000000000000000000000000000000000000000000",
    ],
  },
  {
    event: "IndexedAddress",
    sighash: "0x0fecb3839f031e0e2296f77de64933107916183235e0bd4c07028e4f858287f8",
    matching: ["0x000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266"],
  },
  {
    event: "IndexedBool",
    sighash: "0x61107601b6fdedd0338b9f90e7d00beab2ff818e2896fdad255ed09fc77ca43d",
    matching: ["0x0000000000000000000000000000000000000000000000000000000000000001"],
  },
  {
    event: "IndexedBytes",
    sighash: "0x302971c456dab97076d583d969187faf914418423e0641b0c0f01537060f04e7",
    matching: ["0x1a225f5394ea8eb90a8515ac3013a8d3573052db40af43b7d87c20d608fee005"],
  },
  {
    event: "IndexedString",
    sighash: "0xddb75f21a11f81775d3398c7856efcf0d16770ab01545037b4a09f49ac1aefd0",
    matching: [
      "0x9c22ff5f21f0b81b113e63f7db6da94fedef11b2119b4088b89664fb9a3cb658",
      "0x541801b52322f17e33651df948fa5b57358e8f7db2645051b250a0a2411f0bd8",
    ],
  },
  {
    event: "IndexedFixedBytes",
    sighash: "0xb0eba2ab892fe2f839d66ed0d211b31fcb86dd41dc99ba5a7f5a6e78dc91ef2f",
    matching: ["0x1212121212121212121212121212121212121212121212121212121212121212"],
  },
  {
    event: "IndexedBytes4",
    sighash: "0xe912be8d0680ba3a059ebd4fd19d929b1c0dd86dcdb626739a29a1c00b51ed50",
    matching: ["0x0102030400000000000000000000000000000000000000000000000000000000"],
  },
  {
    event: "IndexedStruct",
    sighash: "0x38c2244c02c10ba340ef114cd25104492582b9c395e2dbd911e2ba4cdfbe4ed6",
    matching: ["0xd0b8769ea9cd15d60ef1800406aa875a74f05fc702bedb0572ea99e06d18257d"],
  },
  // Solidity hashes an indexed array's in-place encoding: the padded elements,
  // without the offset or length prefix regular ABI encoding uses.
  {
    event: "IndexedArray",
    sighash: "0x5d9904ed2bbb0190b69d8f64c0ac688468f2a30b7cb1257ad23b27d1686c0eae",
    matching: ["0xde4717968916aced526cf22f9a203477a82ac23edb99e677f506e50d182b3c4d"],
  },
  {
    event: "IndexedFixedArray",
    sighash: "0xf26d8e215271eeb69bc33c6044f25c731ec4a2b40ebaa5c0e8f67c895bad5f10",
    matching: ["0xde4717968916aced526cf22f9a203477a82ac23edb99e677f506e50d182b3c4d"],
  },
  {
    event: "IndexedNestedArray",
    sighash: "0x50bc90dc53a68a4ed88956cf8eae3d9194d5d67ed1e492fd8192f2967d0816ce",
    matching: ["0x9cd74280be85e33c451783be7e54105bdc6d705b6e0b05836df0153a2ba47a2d"],
  },
  {
    event: "IndexedStructArray",
    sighash: "0xddc88bedbd7d45a12378b523ba713cd4151b2bed8d2538ce1133d69e5519d610",
    matching: ["0x0aba228d60f8731c4d091fc13ecfd996a320396c78c09e6115ee42b6b2e0ad59"],
  },
  {
    event: "IndexedNestedStruct",
    sighash: "0xa83e3eb7d7c87be6c8a1829db259262250b990d633534517bc0de99e1da2c574",
    matching: ["0xdc0d2e5de5ee32cae0b3bd19c32e5863ea705636c11bf11dd2e9d856033d3682"],
  },
  {
    event: "IndexedStructWithArray",
    sighash: "0xa7d2a164937be6e1efa03297b5f743623f5a19addf015fe9fafa3377e3f64b9c",
    matching: ["0x9d1a9024ca624fc8bfc4071fa581a206162ee435dfc42b756e1a70f1b5e4121c"],
  },
]

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let droppedSighash = "0x086d336580debf45b1cc53646f4b6215a2961fe75ee189f2ba7a4e2810189df8"
let unfilteredSighash = "0x94e364d63148732b9673056412f500fa4fd403465df46f3de60a2d56ba8555be"
let bareSighash = "0x823ec8452b495bb33c78d60b8e266cb19e92b9d60a236585edfbcd0204aa113e"

let whitelistedOdd = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
]
let whitelistedEven = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
let outsider = "0x000000000000000000000000000000000000dEaD"

// Indexed case `i` sits in block `i + 1`: its matching logs first, then one
// whose topic1 is the zero word, which no filter below names.
let indexedLogs = indexedCases->Array.flatMapWithIndex(({sighash, matching}, i) =>
  matching
  ->Array.concat([zeroWord])
  ->Array.mapWithIndex((topic1, logIndex): ServedEvmChain.log => {
    blockNumber: i + 1,
    logIndex,
    address: indexedAddress,
    topics: [sighash, topic1],
  })
)

let transfer = (~logIndex, ~from, ~to): ServedEvmChain.log => {
  blockNumber: 20,
  logIndex,
  address: wildcardEmitter,
  topics: [transferSighash, from->ServedEvmChain.addressTopic, to->ServedEvmChain.addressTopic],
  data: 1n->ServedEvmChain.uintTopic,
}

let logs = Array.concat(
  indexedLogs,
  [
    transfer(~logIndex=0, ~from=zero, ~to=whitelistedOdd->Array.getUnsafe(0)),
    transfer(~logIndex=1, ~from=whitelistedOdd->Array.getUnsafe(1), ~to=zero),
    transfer(~logIndex=2, ~from=zero, ~to=whitelistedEven),
    transfer(
      ~logIndex=3,
      ~from=whitelistedOdd->Array.getUnsafe(0),
      ~to=whitelistedOdd->Array.getUnsafe(1),
    ),
    transfer(~logIndex=4, ~from=zero, ~to=outsider),
    {
      blockNumber: 21,
      logIndex: 0,
      address: wildcardEmitter,
      topics: [droppedSighash, zero->ServedEvmChain.addressTopic],
    },
    {
      blockNumber: 21,
      logIndex: 1,
      address: wildcardEmitter,
      topics: [droppedSighash, outsider->ServedEvmChain.addressTopic],
    },
    {
      blockNumber: 22,
      logIndex: 0,
      address: wildcardEmitter,
      topics: [unfilteredSighash, outsider->ServedEvmChain.addressTopic],
    },
    {
      blockNumber: 23,
      logIndex: 0,
      address: indexedAddress,
      topics: [bareSighash, zero->ServedEvmChain.addressTopic],
    },
  ],
)

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18611,
  ~rpcPort=18612,
  ~height=30,
  ~logs,
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-event-where-params
raw_events: true
rollback_on_reorg: false
contracts:
  - name: Indexed
    events:
      - event: IndexedUint(uint256 indexed num)
      - event: IndexedInt(int256 indexed num)
      - event: IndexedAddress(address indexed addr)
      - event: IndexedBool(bool indexed isTrue)
      - event: IndexedBytes(bytes indexed dynBytes)
      - event: IndexedString(string indexed str)
      - event: IndexedFixedBytes(bytes32 indexed fixedBytes)
      - event: IndexedBytes4(bytes4 indexed fourBytes)
      - event: IndexedStruct((uint256 id, string name) indexed testStruct)
      - event: IndexedArray(uint256[] indexed array)
      - event: IndexedFixedArray(uint256[2] indexed array)
      - event: IndexedNestedArray(uint256[2][2] indexed array)
      - event: IndexedStructArray((uint256 id, string name)[2] indexed array)
      - event: IndexedNestedStruct((uint256 id, (uint256 id, string name) testStruct) indexed nestedStruct)
      - event: IndexedStructWithArray((uint256[] numArr, string[2] strArr) indexed structWithArray)
      - event: Bare(address indexed from)
  - name: Filtered
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
      - event: Dropped(address indexed from)
      - event: Unfiltered(address indexed from)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1, 2],
      ~rpc=[3, 4],
      ~contracts=`
      - name: Indexed
        address: "${indexedAddress}"
      - name: Filtered`,
    )}
`,
  ~schema=ServedEvmChain.routedSchema ++ `
type WhereCalls {
  id: ID!
  count: Int!
}
`,
  ~handlers=ServedEvmChain.routedHandlers ++
  `
const id = 50n;
const struct = [id, "test"] satisfies [bigint, string];

indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedUint",
    where: {
      params: {
        num: [id, 115792089237316195423570985008687907853269984665640564039457584007913129639935n],
      },
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedUint")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedInt",
    where: {
      params: {
        num: [-id, -57896044618658097711785492504343953926634992332820282019728792003956564819968n],
      },
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedInt")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedAddress",
    where: { params: { addr: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"] } },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedAddress")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedBool", where: { params: { isTrue: [true] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedBool")),
);
// A second handler on the same event with its own filter gets its own logs.
indexer.onEvent(
  { contract: "Indexed", event: "IndexedBool", where: { params: { isTrue: [false] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedBool-false")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedBytes", where: { params: { dynBytes: ["0x0102030405060709"] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedBytes")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedString", where: { params: { str: ["test", "héllo 🦀"] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedString")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedFixedBytes",
    where: {
      params: {
        fixedBytes: ["0x1212121212121212121212121212121212121212121212121212121212121212"],
      },
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedFixedBytes")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedBytes4", where: { params: { fourBytes: ["0x01020304"] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedBytes4")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedStruct", where: { params: { testStruct: struct } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedStruct")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedArray", where: { params: { array: [[id, id + 1n]] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedArray")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedFixedArray", where: { params: { array: [[id, id + 1n]] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedFixedArray")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedNestedArray",
    where: { params: { array: [[[id, id], [id, id]]] } },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedNestedArray")),
);
indexer.onEvent(
  { contract: "Indexed", event: "IndexedStructArray", where: { params: { array: [[struct, struct]] } } },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedStructArray")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedNestedStruct",
    where: { params: { nestedStruct: [[id, struct]] } },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedNestedStruct")),
);
indexer.onEvent(
  {
    contract: "Indexed",
    event: "IndexedStructWithArray",
    where: { params: { structWithArray: [[[id, id + 1n], ["test", "test"]]] } },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "IndexedStructWithArray")),
);

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const isOdd = (chainId: number) => chainId % 2 === 1;

indexer.onEvent(
  {
    contract: "Filtered",
    event: "Transfer",
    wildcard: true,
    where: ({ chain }) => {
      const whitelisted = isOdd(chain.id)
        ? (["${whitelistedOdd->Array.join(`", "`)}"] as const)
        : (["${whitelistedEven}"] as const);
      return {
        params: [
          { from: ZERO, to: whitelisted },
          { from: whitelisted, to: ZERO },
        ],
      };
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "Transfer")),
);

indexer.onEvent(
  {
    contract: "Filtered",
    event: "Dropped",
    wildcard: true,
    where: ({ chain }) => (isOdd(chain.id) ? { params: { from: ZERO } } : false),
  },
  async ({ event, context }) => context.Routed.set(routed(event, "Dropped")),
);

const whereCalls: Record<number, number> = {};
const countingWhere = ({ chain }: { chain: { id: number } }) => {
  whereCalls[chain.id] = (whereCalls[chain.id] ?? 0) + 1;
  return { params: [] };
};
const unfiltered =
  (tag: string) =>
  async ({ event, context }: { event: Routable; context: any }) => {
    context.Routed.set(routed(event, "Unfiltered-" + tag));
    context.WhereCalls.set({ id: String(event.chainId), count: whereCalls[event.chainId] ?? 0 });
  };
// Two registrations whose callbacks resolve to the same filter: both handlers run.
indexer.onEvent(
  { contract: "Filtered", event: "Unfiltered", wildcard: true, where: countingWhere },
  unfiltered("a"),
);
indexer.onEvent(
  { contract: "Filtered", event: "Unfiltered", wildcard: true, where: countingWhere },
  unfiltered("b"),
);
`,
)

type whereCalls = {id: string, count: int}
type rawEvent = {chain_id: int, event_name: string, block_number: int, log_index: int}

let routed = ServedEvmChain.routed

let expectedRows =
  [1, 2, 3, 4]
  ->Array.flatMap(chainId =>
    Array.concat(
      indexedCases->Array.flatMapWithIndex(({event, matching}, i) =>
        matching->Array.mapWithIndex(
          (_, logIndex) => routed(~chainId, ~blockNumber=i + 1, ~logIndex, event),
        )
      ),
      Array.concat(
        mod(chainId, 2) === 1
          ? [
              routed(~chainId, ~blockNumber=20, "Transfer"),
              routed(~chainId, ~blockNumber=20, ~logIndex=1, "Transfer"),
              routed(~chainId, ~blockNumber=21, "Dropped"),
            ]
          : [routed(~chainId, ~blockNumber=20, ~logIndex=2, "Transfer")],
        [
          // IndexedBool's non-matching log: topic1 is the zero word, false.
          routed(~chainId, ~blockNumber=4, ~logIndex=1, "IndexedBool-false"),
          routed(~chainId, ~blockNumber=22, "Unfiltered-a"),
          routed(~chainId, ~blockNumber=22, "Unfiltered-b"),
        ],
      ),
    )
  )
  ->ServedEvmChain.sorted

let readRawEvents = async (sql, ~pgSchema) => {
  let rows: array<rawEvent> = await sql->Sql.queryForTests(
    `SELECT "chain_id", "event_name", "block_number", "log_index"
       FROM "${pgSchema}"."raw_events"
       WHERE "event_name" IN ('Dropped', 'Bare')
       ORDER BY "chain_id", "block_number", "log_index";`,
  )
  rows
}

describe("onEvent where params", () => {
  Async.it(
    "index only the logs each chain's filter matches, over HyperSync and RPC alike",
    async t =>
      await served->ServedEvmChain.run(
        scenario,
        async indexer => {
          let whereCalls: array<whereCalls> = await indexer.query("WhereCalls")
          t.expect((
            await indexer->ServedEvmChain.readRouted,
            whereCalls->Array.toSorted((a, b) => String.compare(a.id, b.id)),
          )).toEqual((
            expectedRows,
            // Two callbacks, each called once per chain.
            [1, 2, 3, 4]->Array.map(chainId => {id: chainId->Int.toString, count: 2}),
          ))
          // A `false` where drops the event from its chain entirely, raw events
          // included, while an event with no handler is still kept raw.
          await indexer.usePostgresSql(
            async sql =>
              t.expect(await sql->readRawEvents(~pgSchema=indexer.pgSchema)).toEqual([
                {chain_id: 1, event_name: "Dropped", block_number: 21, log_index: 0},
                {chain_id: 1, event_name: "Bare", block_number: 23, log_index: 0},
                {chain_id: 2, event_name: "Bare", block_number: 23, log_index: 0},
                {chain_id: 3, event_name: "Dropped", block_number: 21, log_index: 0},
                {chain_id: 3, event_name: "Bare", block_number: 23, log_index: 0},
                {chain_id: 4, event_name: "Bare", block_number: 23, log_index: 0},
              ]),
          )
        },
      ),
  )
})
