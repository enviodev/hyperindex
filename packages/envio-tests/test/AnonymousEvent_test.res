open Vitest

// Anonymous events, from a user's config.yaml and handler source to the rows the
// indexer writes. An anonymous log has no signature topic: its first indexed
// param sits in topic0, so every registration selects its logs by that param.
// Chain 1 fetches over HyperSync and chain 2 over RPC, from the same served
// logs. `Vat` declares LogNote by signature, `Jug` through an ABI file.

let vat = "0x1111111111111111111111111111111111111111"
let jug = "0x2222222222222222222222222222222222222222"
let guy = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
let otherGuy = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

let fileSig = "0x29ae8114"
let slipSig = "0x7cdd3fde"
let moveSig = "0xbb35783b"
let unlistedSig = "0xdeadbeef"
let frobSighash = "0x5d8393492ea0325a1e5b50f999521e134cc91ed12ba0964b67e7751c8c71a88c"

// A bytes4 topic is left-aligned: the selector, then zero bytes.
let sigTopic = sig => sig ++ String.repeat("0", 56)
let foo = ServedEvmChain.word("f00")
let bar = ServedEvmChain.word("ba7")
let fax = "0xabcdef"

// `abi.encode(uint256 wad, bytes fax)` with fax = 0xabcdef.
let noteData = wad =>
  ServedEvmChain.uintTopic(wad) ++
  ServedEvmChain.word("40")->ServedEvmChain.dropPrefix ++
  ServedEvmChain.word("3")->ServedEvmChain.dropPrefix ++
  "abcdef"->String.padEnd(64, "0")

let note = (~address=vat, ~guy=guy, ~blockNumber, sig): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address,
  topics: [sig->sigTopic, guy->ServedEvmChain.addressTopic, foo, bar],
  data: noteData(blockNumber->BigInt.fromInt),
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18617,
  ~rpcPort=18618,
  ~height=10,
  ~logs=[
    note(~blockNumber=1, fileSig),
    note(~blockNumber=2, slipSig),
    note(~blockNumber=3, moveSig),
    note(~blockNumber=4, unlistedSig),
    // A regular event with as many topics as LogNote.
    {
      blockNumber: 5,
      logIndex: 0,
      address: vat,
      topics: [
        frobSighash,
        guy->ServedEvmChain.addressTopic,
        otherGuy->ServedEvmChain.addressTopic,
        ServedEvmChain.word("7"),
      ],
    },
    note(~address=jug, ~blockNumber=6, fileSig),
    note(~address=jug, ~guy=otherGuy, ~blockNumber=7, fileSig),
    note(~address=jug, ~blockNumber=8, slipSig),
  ],
)

let jugAbi = `[
  {
    "type": "event",
    "name": "LogNote",
    "anonymous": true,
    "inputs": [
      { "name": "sig", "type": "bytes4", "indexed": true },
      { "name": "guy", "type": "address", "indexed": true },
      { "name": "foo", "type": "bytes32", "indexed": true },
      { "name": "bar", "type": "bytes32", "indexed": true },
      { "name": "wad", "type": "uint256", "indexed": false },
      { "name": "fax", "type": "bytes", "indexed": false }
    ]
  }
]`

let scenario = Scenario.make(
  ~configYaml=`
name: anonymous-event
contracts:
  - name: Vat
    events:
      - event: LogNote(bytes4 indexed sig, address indexed guy, bytes32 indexed foo, bytes32 indexed bar, uint256 wad, bytes fax) anonymous
      - event: Frob(address indexed u, address indexed v, uint256 indexed dink)
  - name: Jug
    abi_file_path: abis/Jug.json
    events:
      - event: LogNote
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Vat
        address: "${vat}"
      - name: Jug
        address: "${jug}"`,
    )}
`,
  ~files=dict{"abis/Jug.json": jugAbi},
  ~schema=ServedEvmChain.routedSchema ++ `
type Note {
  id: ID!
  sig: String!
  guy: String!
  foo: String!
  bar: String!
  wad: String!
  fax: String!
}
`,
  ~handlers=ServedEvmChain.routedHandlers ++
  `
type NoteEvent = Routable & {
  params: { sig: string; guy: string; foo: string; bar: string; wad: bigint; fax: string };
};
const note = (event: NoteEvent, name: string) => ({
  ...routed(event, name),
  sig: event.params.sig,
  guy: event.params.guy,
  foo: event.params.foo,
  bar: event.params.bar,
  wad: event.params.wad.toString(),
  fax: event.params.fax,
});

indexer.onEvent(
  { contract: "Vat", event: "LogNote", where: { params: { sig: "${fileSig}" } } },
  async ({ event, context }) => context.Note.set(note(event, "file")),
);
indexer.onEvent(
  { contract: "Vat", event: "LogNote", where: { params: { sig: ["${slipSig}", "${moveSig}"] } } },
  async ({ event, context }) => context.Note.set(note(event, "slip-or-move")),
);
indexer.onEvent(
  { contract: "Vat", event: "Frob" },
  async ({ event, context }) => context.Routed.set(routed(event, "Frob")),
);
indexer.onEvent(
  {
    contract: "Jug",
    event: "LogNote",
    where: ({ chain }) =>
      chain.id === 0 ? false : { params: [{ sig: "${fileSig}", guy: "${guy}" as const }] },
  },
  async ({ event, context }) => context.Note.set(note(event, "jug-file")),
);
`,
)

type noteRow = {
  id: string,
  sig: string,
  guy: string,
  foo: string,
  bar: string,
  wad: string,
  fax: string,
}

let readNotes = async (indexer: IndexerRunner.t) => {
  let rows: array<noteRow> = await indexer.query("Note")
  rows->Array.toSorted((a, b) => String.compare(a.id, b.id))
}

// Which handler saw which log: each listed sig once, and Jug's sig only for the
// guy its filter names.
let expectedNotes =
  [1, 2]
  ->Array.flatMap(chainId =>
    [
      (1, fileSig, "file"),
      (2, slipSig, "slip-or-move"),
      (3, moveSig, "slip-or-move"),
      (6, fileSig, "jug-file"),
    ]->Array.map(((blockNumber, sig, name)) => {
      id: ServedEvmChain.routed(~chainId, ~blockNumber, name),
      sig,
      guy,
      foo,
      bar,
      wad: blockNumber->Int.toString,
      fax,
    })
  )
  ->Array.toSorted((a, b) => String.compare(a.id, b.id))

let key = filter => JSON.stringifyAny(filter)->Option.getOrThrow

// The distinct log filters a source sent, in a stable order.
let distinctFilters = (filters: array<ServedEvmChain.logFilter>) => {
  let byKey = Dict.make()
  filters->Array.forEach(filter => byKey->Dict.set(filter->key, filter))
  byKey->Dict.valuesToArray->Array.toSorted((a, b) => String.compare(a->key, b->key))
}

let sentFilters = (queries: array<ServedEvmChain.query>) =>
  queries->Array.flatMap(query => query.filters)->distinctFilters

let one = value => [value->String.toLowerCase]

// Each contract's own query: Vat's sigs fold into one topic0 list beside
// Frob's signature, Jug's filter also names the guy. RPC leaves out the
// trailing positions that match anything.
let expectedFilters = (~trailing) =>
  distinctFilters([
    {
      address: [vat],
      topics: [
        [
          [
            frobSighash,
            fileSig->sigTopic,
            slipSig->sigTopic,
            moveSig->sigTopic,
          ]->ServedEvmChain.normalize,
        ],
        trailing ? [[], [], []] : [],
      ]->Array.flat,
    },
    {
      address: [jug],
      topics: [
        [fileSig->sigTopic->one, guy->ServedEvmChain.addressTopic->one],
        trailing ? [[], []] : [],
      ]->Array.flat,
    },
  ])

describe("anonymous events", () => {
  Async.it(
    "index the logs whose first indexed param each registration names, over HyperSync and RPC alike",
    async t =>
      await served->ServedEvmChain.run(
        scenario,
        async indexer =>
          t.expect((
            await readNotes(indexer),
            await indexer->ServedEvmChain.readRouted,
            served->ServedEvmChain.takeHyperSyncQueries->sentFilters,
            served->ServedEvmChain.takeRpcQueries->sentFilters,
          )).toEqual((
            expectedNotes,
            [1, 2]->Array.map(chainId => ServedEvmChain.routed(~chainId, ~blockNumber=5, "Frob")),
            expectedFilters(~trailing=true),
            expectedFilters(~trailing=false),
          )),
      ),
  )
})
