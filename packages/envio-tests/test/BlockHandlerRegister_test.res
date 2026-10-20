open Vitest

// Subgraph mode: a block handler's register pass registers the data sources
// its block creates, at that block, so they live and die with it. graph-node
// reverts a reorged block's dynamic data sources with the rest of its state
// (store/postgres/src/dynds/private.rs, `revert`: it deletes the data sources
// whose `block_range` starts above the reverted-to block), and creates again
// whatever the new fork's block creates.
let scenario = Scenario.make(
  ~configYaml=`
name: block-handler-register
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
      - name: Pool
        events:
          - event: Epoch(uint256 id)
`,
  ~handlers=`
import { indexer } from "envio";

const registry = globalThis as any;
registry.__blockRegisterPasses = [];

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Pool", event: "Epoch" }, async () => {});

// What the subgraph runtime hands a creating block handler; not public API.
indexer.onBlock(
  {
    name: "creator",
    where: () => ({ block: { number: { _gte: 150, _lte: 150 } } }),
    contractRegister: async ({ block, context }: any) => {
      registry.__blockRegisterPasses.push(block.number);
      context.chain.Pool.add(
        registry.__blockRegisterFork
          ? "0x0000000000000000000000000000000000000003"
          : "0x0000000000000000000000000000000000000002",
      );
    },
  } as any,
  async () => {},
);
`,
)

let setFork: bool => unit = %raw(`(fork) => { globalThis.__blockRegisterFork = fork }`)
let registerPasses: unit => array<int> = %raw(`() => globalThis.__blockRegisterPasses`)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let poolAddresses = async (indexer: IndexerRunner.t) =>
  (await indexer.queryAddresses())
  ->Array.filter(row => row.contractName === "Pool")
  ->Array.map(row => (row.address->Address.toString, row.registrationBlock))

// Answers every item query and block-hash lookup the indexer makes, as a chain
// whose blocks past `validUpTo` were reorged, until `until` holds.
let drive = async (~source: MockSource.t, ~head, ~validUpTo, ~until) => {
  let deadline = Date.now() +. 20_000.
  while !(await until()) && Date.now() < deadline {
    if source.getBlockHashesCalls->Array.length > 0 {
      let requested = source.getBlockHashesCalls->Array.copy
      source.resolveGetBlockHashes(
        requested
        ->Array.flat
        ->Array.map((blockNumber): BlockStore.inputBlock => {
          blockNumber,
          blockHash: blockNumber <= validUpTo
            ? `0x${blockNumber->Int.toString}`
            : `0x${blockNumber->Int.toString}a`,
          blockTimestamp: blockNumber,
        }),
      )
      source.getBlockHashesCalls->Utils.Array.clearInPlace
    }
    source.getItemsOrThrowCalls
    ->Array.copy
    ->Array.forEach(call =>
      call.resolve(
        [],
        ~latestFetchedBlockNumber=switch call.payload["toBlock"] {
        | Some(toBlock) => Pervasives.min(toBlock, head)
        | None => head
        },
      )
    )
    await Utils.delay(1)
  }
}

let pool2 = ("0x0000000000000000000000000000000000000002", 150)
let pool3 = ("0x0000000000000000000000000000000000000003", 150)

describe("a data source a block handler creates", () => {
  beforeAll(() => Env.subgraphMode := true)
  beforeEach(() => setFork(false))
  afterAll(() => {
    Env.subgraphMode := false
    setFork(false)
  })

  scenario->Scenario.it(
    "is rolled back with its block, and the new fork's block creates its own",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await drive(
        ~source,
        ~head=300,
        ~validUpTo=300,
        ~until=async () => (await poolAddresses(indexer))->Array.length > 0,
      )
      t.expect(
        await poolAddresses(indexer),
        ~message="the block handler's create is registered at its block",
      ).toEqual([pool2])

      // Block 301 doesn't build on the stored 300: only blocks up to 100 still
      // hold, so block 150 and what it created are gone, and block 150 of the
      // new fork creates 0x…03 instead.
      setFork(true)
      source.resolveGetHeightOrThrow(301)
      let headQueries = () =>
        source.getItemsOrThrowCalls->Array.filter(call => call.payload["fromBlock"] === 301)
      await Scenario.waitUntil(
        () => headQueries()->Utils.Array.notEmpty,
        ~message="the chain queries the new head",
      )
      headQueries()->Array.forEach(
        call =>
          call.resolve(
            [],
            ~latestFetchedBlockNumber=301,
            ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
          ),
      )
      await drive(
        ~source,
        ~head=301,
        ~validUpTo=100,
        ~until=async () => (await poolAddresses(indexer))->Array.includes(pool3),
      )
      t.expect(
        (await poolAddresses(indexer), registerPasses()),
        ~message="only the new fork's create stays, and the pass ran again on its block",
      ).toEqual(([pool3], [150, 150]))
    },
  )

  scenario->Scenario.it(
    "stays registered across a restart, without its pass running again",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await drive(
        ~source,
        ~head=300,
        ~validUpTo=300,
        ~until=async () => (await poolAddresses(indexer))->Array.length > 0,
      )
      let passesBefore = registerPasses()->Array.length
      source.setAutoHeight(300)
      let restarted = await indexer.restart()
      let rounds = ref(0)
      await drive(
        ~source,
        ~head=300,
        ~validUpTo=300,
        ~until=async () => {
          rounds := rounds.contents + 1
          rounds.contents > 50
        },
      )
      await restarted.waitUntilIdle()
      t.expect(
        (await poolAddresses(restarted), registerPasses()->Array.length - passesBefore),
        ~message="the address resumes from storage and block 150 isn't passed again",
      ).toEqual(([pool2], 0))
    },
  )
})
