// What the live transaction-handler tests index and expect: every USDT
// `transfer` call of mainnet block 26400000, read from a public RPC node
// independently of either source.

let block = 26400000

let schema = `
type UsdtTransfer {
  id: ID!
  transactionIndex: Int!
  from: String!
  status: Int!
  gasUsed: BigInt!
  timestamp: Int!
}
`

let handlers = `
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "usdt-transfers",
    where: () => ({
      transaction: {
        to: ["0xdac17f958d2ee523a2206206994597c13d831ec7"],
        sighash: ["0xa9059cbb"],
      },
    }),
    fields: { transaction: ["status", "gasUsed"] },
  },
  async ({ transaction, block, context }) => {
    context.UsdtTransfer.set({
      id: transaction.hash,
      transactionIndex: transaction.transactionIndex,
      from: (transaction.from ?? "").toLowerCase(),
      status: transaction.status ?? -1,
      gasUsed: transaction.gasUsed,
      timestamp: block.timestamp,
    });
  },
);
`

let expected = `[
  { id: "0x53d34c4092b74252a5b1c72bc5616a82d2ec0f92bb664be77a5ba8dbb1a53d86", transactionIndex: 0, from: "0x5f00a0c77be99cf07f68554ba7b687869384798d", status: 1, gasUsed: 41309n, timestamp: 1794500183 },
  { id: "0x8482bbb9a34bb18fa411b23b3f91296511c6b0fe450333776aba20c8272bc3f5", transactionIndex: 16, from: "0xaa8ba7d4611437141192e7ceced531bc0a133efb", status: 1, gasUsed: 63209n, timestamp: 1794500183 },
  { id: "0xe448f715cf24463036e7b167ca1402efbbab64165f55e8ce34998fe795e5bcee", transactionIndex: 23, from: "0xc6fe7b7fbc7ef114284896a6631251cf54a8c304", status: 1, gasUsed: 63209n, timestamp: 1794500183 },
  { id: "0x00c5725e508904e665cee9ff3f0717224d443004b50847f4c9636a2ed6522110", transactionIndex: 39, from: "0x342bd0b04b7165e42e3a17762a70ca54b727f2c4", status: 1, gasUsed: 46097n, timestamp: 1794500183 },
  { id: "0xdc19553592c84984a3421c2a05abacecbc5f00c698c523374f83bb81043bf554", transactionIndex: 47, from: "0x40a55099c49d2b182e196af1898bd13a180cec66", status: 1, gasUsed: 63209n, timestamp: 1794500183 },
  { id: "0x646c800d45881e3eada715fd889c48cd01dd8db26b51e241c8f23cbb7ac870be", transactionIndex: 50, from: "0x483ecbbf180cbbb9661fb6b5848e09092ff47354", status: 1, gasUsed: 63197n, timestamp: 1794500183 },
  { id: "0xd99f94716f2309396d45269c2de007dd9b0c75f9b754de7599791c8455c94593", transactionIndex: 51, from: "0x3863d11f4e0b367ac08ca9967308d07322ce92db", status: 1, gasUsed: 46109n, timestamp: 1794500183 },
  { id: "0x43d00c3d3e49ca9ffaa9581677d962161543c1e48d6e731ade896884786f6e13", transactionIndex: 60, from: "0xaeb70cbc59361665dce0e2829c198b3cdc9729f3", status: 1, gasUsed: 46097n, timestamp: 1794500183 },
  { id: "0x1e8c09646eb519593a2e2870d18b16612591db7b4c730a2e3ad8650a61abb8e4", transactionIndex: 65, from: "0x6892ba7febc703d19aebb35b79846f1fe33153c8", status: 1, gasUsed: 46109n, timestamp: 1794500183 },
  { id: "0x836f01ad1fab39566857f4f0c8fda6245216b61664a533a387d12515e3bb71be", transactionIndex: 70, from: "0xb8001c3ec9aa1985f6c747e25c28324e4a361ec1", status: 1, gasUsed: 63209n, timestamp: 1794500183 },
  { id: "0xe9a2b67b7c4c22f9995b470b1b3b9cedd6e33d7543551e5d12baf1d67a225bac", transactionIndex: 71, from: "0xb8001c3ec9aa1985f6c747e25c28324e4a361ec1", status: 1, gasUsed: 63197n, timestamp: 1794500183 },
  { id: "0x249e4b29ba3b6b991d2928671e70202c25b4a0c4ac296d2bb097d96f333ce9b7", transactionIndex: 72, from: "0xb8001c3ec9aa1985f6c747e25c28324e4a361ec1", status: 1, gasUsed: 46109n, timestamp: 1794500183 },
  { id: "0x6d8f16249c6acacfbb28db085362eb2571375cf51af4f6dff125693b18cb122b", transactionIndex: 85, from: "0x253dd57300904225762960755b7662e6ae06492d", status: 1, gasUsed: 46109n, timestamp: 1794500183 },
  { id: "0x7a73e411ef9083683d9b698ffad1b99fcae8910e244d965244f5ff4df9b356f6", transactionIndex: 86, from: "0x28effad61aecf3a9e68aeb2e6d5ab742220aec7e", status: 1, gasUsed: 46097n, timestamp: 1794500183 },
  { id: "0x882aa28b2e97b12aba12493445f9c30fa648657670497732647b1da87758cafd", transactionIndex: 87, from: "0xf1088841ab08fc1cb3835fd75207bcb3137f6ee3", status: 1, gasUsed: 63209n, timestamp: 1794500183 },
]`

let test = (~title) =>
  `
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("${title}", () => {
  it("runs on every USDT transfer call of the block, with its fields", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: ${block->Int.toString}, endBlock: ${block->Int.toString} } } });
    t.expect(
      (await indexer.UsdtTransfer.getAll()).sort((a, b) => a.transactionIndex - b.transactionIndex),
    ).toEqual(${expected});
  });
});
`
