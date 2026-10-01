// Live test against fuel-testnet.hypersync.xyz, driven through the user API:
// real config, real handlers, the real source, routing and LogData decoding.
// The pinned transaction logs one receipt per AllEvents logged type, so this
// pins the JS values handlers receive for every shape the contract emits —
// the shapes the generated types are tagged on: enums (Option included) as
// `{case, payload}` with an undefined payload for unit variants, u64 and wider
// as bigint, b256 as `0x` hex, Bytes as Uint8Array.

let block = 22158283

let events = [
  "UnitLog",
  "BoolLog",
  "U8Log",
  "U16Log",
  "U32Log",
  "U64Log",
  "UnknownLog",
  "StrLog",
  "StringLog",
  "B256Log",
  "TupleLog",
  "ArrayLog",
  "Result",
  "Option_",
  "Option2",
  "SimpleStruct",
  "SimpleStructWithOptionalField",
  "Status",
  "VecLog",
  "TagsEvent",
  "BytesLog",
]

let logIds = dict{
  "UnitLog": "3330666440490685604",
  "BoolLog": "13213829929622723620",
  "U8Log": "14454674236531057292",
  "U16Log": "2992671284987479467",
  "U32Log": "15520703124961489725",
  "U64Log": "1515152261580153489",
  "UnknownLog": "1970142151624111756",
  "StrLog": "10732353433239600734",
  "StringLog": "11132648958528852192",
  "B256Log": "8961848586872524460",
  "TupleLog": "6486780880364592010",
  "ArrayLog": "12456997331598520636",
  "Result": "499881700873475792",
  "Option_": "10927802446890217233",
  "Option2": "8688528864679113840",
  "SimpleStruct": "8500535089865083573",
  "SimpleStructWithOptionalField": "3525891009499019808",
  "Status": "7417129983252335614",
  "VecLog": "15402277555065905665",
  "TagsEvent": "8843604259160078410",
  "BytesLog": "14832741149864513620",
}

let _ = InternalTestIndexer.fromUserApi(
  ~files=dict{"abis/all-events-abi.json": FuelAbiFixtures.allEvents},
  ~configYaml=`
name: fuel-log-data-live
ecosystem: fuel
chains:
  - id: 0
    start_block: ${block->Int.toString}
    end_block: ${block->Int.toString}
    contracts:
      - name: AllEvents
        address: 0xd298efffbf3cdf38b4b55ffe76a97a67b9146d7edd61b92cca730bd6e0eb415d
        abi_file_path: abis/all-events-abi.json
        events:
${events
    ->Array.map(name =>
      `          - name: ${name}
            logId: "${logIds->Dict.getUnsafe(name)}"`
    )
    ->Array.join("\n")}
`,
  ~schema=`
type Log {
  id: ID!
  event: String!
  params: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

// Renders a JS value so every distinction a handler can observe survives:
// number vs bigint vs string, an undefined property, a Uint8Array, key order.
const show = (value: unknown): string =>
  value === undefined
    ? "undefined"
    : value === null
      ? "null"
      : typeof value === "bigint"
        ? \`\${value}n\`
        : value instanceof Uint8Array
          ? \`Uint8Array[\${value.join(",")}]\`
          : Array.isArray(value)
            ? \`[\${value.map(show).join(",")}]\`
            : typeof value === "object"
              ? \`{\${Object.entries(value).map(([key, item]) => \`\${key}:\${show(item)}\`).join(",")}}\`
              : JSON.stringify(value);

${events
    ->Array.map(name =>
      `indexer.onEvent({ contract: "AllEvents", event: "${name}" }, async ({ event, context }) => {
  context.Log.set({ id: String(event.logIndex), event: "${name}", params: show(event.params) });
});`
    )
    ->Array.join("\n")}
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Fuel LogData decoding (live)", () => {
  it(
    "hands handlers the JS values of every AllEvents logged type",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 0: { startBlock: ${block->Int.toString}, endBlock: ${block->Int.toString} } } });

      const logs = await indexer.Log.getAll();
      t.expect(
        logs
          .sort((a, b) => Number(a.id) - Number(b.id))
          .map((log) => [Number(log.id), log.event, log.params]),
      ).toEqual([
        [1, "UnitLog", "undefined"],
        [2, "BoolLog", "true"],
        [3, "BoolLog", "false"],
        [4, "U8Log", "3"],
        [5, "U16Log", "4"],
        [6, "U32Log", "5"],
        [7, "U64Log", "6n"],
        [8, "UnknownLog", "7n"],
        [9, "StrLog", '"abcd"'],
        [10, "StringLog", '"abcd"'],
        [11, "B256Log", '"0x0000000000000000000000000000000000000000000000000000000000000001"'],
        [12, "TupleLog", "[42n,true]"],
        [13, "ArrayLog", "[1,2,3,4,5]"],
        [14, "Result", '{case:"Ok",payload:12}'],
        [15, "Result", '{case:"Err",payload:false}'],
        [16, "Option_", '{case:"None",payload:undefined}'],
        [17, "Option_", '{case:"Some",payload:12}'],
        [18, "Option2", '{case:"None",payload:undefined}'],
        [19, "Option2", '{case:"Some",payload:{case:"None",payload:undefined}}'],
        [20, "Option2", '{case:"Some",payload:{case:"Some",payload:12}}'],
        [21, "SimpleStruct", "{f1:11}"],
        [22, "SimpleStructWithOptionalField", '{f1:11,f2:{case:"None",payload:undefined}}'],
        [23, "SimpleStructWithOptionalField", '{f1:11,f2:{case:"Some",payload:32}}'],
        [24, "Status", '{case:"Pending",payload:undefined}'],
        [25, "Status", '{case:"Completed",payload:12}'],
        [26, "Status", '{case:"Failed",payload:{reason:1}}'],
        [27, "VecLog", "[69n,23n]"],
        [28, "TagsEvent", '{tags:{case:"Some",payload:["abcd"]}}'],
        [29, "BytesLog", "Uint8Array[40]"],
      ]);
    },
    300_000,
  );
});
`,
)
