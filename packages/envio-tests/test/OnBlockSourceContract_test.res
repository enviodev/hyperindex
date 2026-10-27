open Vitest

// A block handler selecting fields is a selection on the block table, which a
// source fetches like the log table: the query asks for the blocks, and the
// source routes each to the handlers that run on it.

let minerAddress = "0x000000000000000000000000000000000000beef"
let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")

let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-block-source-contract
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock(
  {
    name: "headers",
    where: () => ({ block: { number: { _gte: 10, _every: 2 } } }),
    fields: { block: ["timestamp", "miner"] },
  },
  async ({ block }) => {
    block.timestamp;
    block.miner;
  },
);

indexer.onBlock(
  {
    name: "sparse",
    where: () => ({ block: { number: { _gte: 10, _every: 5000 } } }),
    fields: { block: ["miner"] },
  },
  async ({ block }) => {
    block.miner;
  },
);

indexer.onBlock(
  {
    name: "early",
    where: () => ({ block: { number: { _gte: 0, _lte: 5 } } }),
    fields: { block: ["miner"] },
  },
  async ({ block }) => {
    block.miner;
  },
);
`,
  ~registerHandlers=true,
)

let onBlockRegistrations = () => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    parsed.registrations()->Utils.Dict.dangerouslyGetNonOption("1")->Option.getOrThrow
  chainRegistrations.onBlockRegistrations
}

let named = name => onBlockRegistrations()->Array.filter(reg => reg.name === name)

let makeHyperSyncSource = (~url) => {
  let addressStore = TestAddresses.storeOf(~contracts=[], ~addresses=[])
  let source = EvmHyperSyncSource.make({
    chainId: 1->ChainId.fromInt,
    endpointUrl: url,
    onEventRegistrations: [],
    onBlockRegistrations: onBlockRegistrations(),
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses: true,
    serializationFormat: Json,
    enableQueryCaching: false,
    logLevel: #error,
    addressStore,
    logger: Logger.makeInMemory(),
  })
  (source, addressStore->AddressStore.emptySet)
}

let fetch = (
  source: Source.t,
  ~addressSet,
  ~onBlockRegistrations=named("headers"),
  ~toBlock=Some(13),
  ~knownHeight=100,
  ~includeAllBlocks=false,
  ~itemsTarget=None,
) =>
  source.getItemsOrThrow(
    ~fromBlock=10,
    ~toBlock,
    ~addressSet,
    ~includeAllBlocks,
    ~knownHeight,
    ~partitionId="0",
    ~selection=FetchState.makeSelection(
      ~dependsOnAddresses=false,
      ~onEventRegistrations=[],
      ~onBlockRegistrations,
    ),
    ~itemsTarget,
    ~retry=0,
    ~logger=Logger.makeInMemory()->Logger.withFields({"test": "onBlock source contract"}),
  )

let header = number =>
  JSON.parseOrThrow(
    `{"number":${number->Int.toString},"timestamp":${(1_700_000_000 + number)
        ->Int.toString},"hash":"${blockHash(number)}","miner":"${minerAddress}"}`,
  )

type blockView = {number: int, timestamp?: int, miner?: Address.t}

// What a block handler runs with, once the page's blocks are materialised.
let materializedBlocks = async (page: Source.blockRangeFetchResponse) => {
  await ChainState.materializePageItems(
    ~items=page.parsedQueueItems,
    ~transactionStore=TransactionStore.make(~ecosystem=Evm),
    ~blockStore=page.blockStore,
    ~shouldChecksum=false,
  )
  page.parsedQueueItems->Array.map(item =>
    switch item {
    | Internal.Block({onBlockRegistration, blockNumber, ?block}) => (
        onBlockRegistration.name,
        blockNumber,
        block->Option.map(block => block->(Utils.magic: Internal.eventBlock => blockView)),
      )
    | Internal.Event(_) => JsError.throwWithMessage("Expected a block item")
    }
  )
}

let makeRpcSource = (~url) => {
  let addressStore = TestAddresses.storeOf(~contracts=[], ~addresses=[])
  let source = RpcSource.make({
    url,
    chainId: 1->ChainId.fromInt,
    onEventRegistrations: [],
    onBlockRegistrations: onBlockRegistrations(),
    sourceFor: Sync,
    syncConfig: EvmChain.getSyncConfig({
      initialBlockInterval: 100,
      intervalCeiling: 100,
      backoffMillis: 1,
      queryTimeoutMillis: 1_000,
    }),
    lowercaseAddresses: true,
    addressStore,
    blockStore: BlockStore.make(~ecosystem=Evm),
    transactionStore: TransactionStore.make(~ecosystem=Evm),
  })
  (source, addressStore->AddressStore.emptySet)
}

let rpcBlock = number => {
  let hex = n => "0x" ++ n->Int.toString(~radix=16)
  JSON.parseOrThrow(
    `{"number":"${hex(number)}","timestamp":"${hex(1_700_000_000 + number)}","hash":"${blockHash(
        number,
      )}","parentHash":"${blockHash(number - 1)}","miner":"${minerAddress}"}`,
  )
}

let getBlockCall = number =>
  MockRpcServer.expectCall(
    ~label=`block ${number->Int.toString}`,
    ~method="eth_getBlockByNumber",
    ~params=JSON.parseOrThrow(`["0x${number->Int.toString(~radix=16)}",false]`),
    ~reply=RpcResult(rpcBlock(number)),
  )

describe("A block handler selecting fields, fetched from an RPC", () => {
  // No log is asked for, and of the blocks the handler skips only the range's
  // last is read, as every page reads its boundary for reorg detection.
  Async.it("reads the blocks the handler runs on, with its fields", async t => {
    let blocks = await MockRpcServer.withScenario(
      ~name="block handler page",
      ~calls=[10, 12, 13]->Array.map(getBlockCall),
      async mock => {
        let (source, addressSet) = makeRpcSource(~url=mock.url)
        await (await source->fetch(~addressSet))->materializedBlocks
      },
    )

    t.expect(blocks).toEqual([
      (
        "headers",
        10,
        Some({
          number: 10,
          timestamp: 1_700_000_010,
          miner: minerAddress->Address.unsafeFromString,
        }),
      ),
      (
        "headers",
        12,
        Some({
          number: 12,
          timestamp: 1_700_000_012,
          miner: minerAddress->Address.unsafeFromString,
        }),
      ),
    ])
  })
})

describe("A block handler selecting fields, fetched from HyperSync", () => {
  // The range's last block runs no handler, yet the page has read it.
  Async.it("asks for every block in the range with the selected fields", async t => {
    let (queries, latestFetchedBlockNumber) = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 12, 13]->Array.map(header)})
        let page = await source->fetch(~addressSet)
        (server->MockHyperSyncServer.takeQueries, page.latestFetchedBlockNumber)
      },
    )

    t.expect((queries, latestFetchedBlockNumber)).toEqual((
      [
        JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 14,
        "include_all_blocks": true,
        "field_selection": {"block": ["hash", "miner", "number", "timestamp"]}
      }`),
      ],
      13,
    ))
  })

  // A selection with nothing to read in the range holds nothing there; on SVM,
  // a query selecting nothing would even return every instruction.
  Async.it("sends no query when no handler runs in the range", async t => {
    let (queries, latestFetchedBlockNumber) = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        let page = await source->fetch(~addressSet, ~onBlockRegistrations=named("early"))
        (server->MockHyperSyncServer.takeQueries, page.latestFetchedBlockNumber)
      },
    )

    t.expect((queries, latestFetchedBlockNumber)).toEqual(([], 13))
  })

  // At the head the page's hashes feed reorg detection, so it is sent even
  // with no handler block to read.
  Async.it("still sends a realtime query when no handler runs in the range", async t => {
    let queries = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 12, 13]->Array.map(header)})
        let _ = await source->fetch(
          ~addressSet,
          ~onBlockRegistrations=named("early"),
          ~includeAllBlocks=true,
        )
        server->MockHyperSyncServer.takeQueries
      },
    )

    t.expect(queries).toEqual([
      JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 14,
        "include_all_blocks": true,
        "field_selection": {"block": ["hash", "number", "timestamp"]}
      }`),
    ])
  })

  // Every block between two a handler runs on would cost more to read than a
  // request per handler block, so the page reads the one block and answers for
  // the gap up to the next.
  Async.it("reads a sparse handler's block alone and claims the gap after it", async t => {
    let (queries, page) = await MockHyperSyncServer.withServer(
      ~height=20_000,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [header(10)]})
        let page = await source->fetch(
          ~addressSet,
          ~onBlockRegistrations=named("sparse"),
          ~toBlock=Some(20_000),
          ~knownHeight=20_000,
        )
        (server->MockHyperSyncServer.takeQueries, page)
      },
    )

    t.expect((
      queries,
      page.latestFetchedBlockNumber,
      page.parsedQueueItems->Array.map(Internal.getItemBlockNumber),
    )).toEqual((
      [
        JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 11,
        "include_all_blocks": true,
        "field_selection": {"block": ["hash", "miner", "number", "timestamp"]}
      }`),
      ],
      5009,
      [10],
    ))
  })

  // A query open to the head reads up to the height the chain knows, so the
  // gap a page claims never runs past it.
  Async.it("bounds an open-ended sparse page at the known height", async t => {
    let (queries, latestFetchedBlockNumber) = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [header(10)]})
        let page = await source->fetch(
          ~addressSet,
          ~onBlockRegistrations=named("sparse"),
          ~toBlock=None,
        )
        (server->MockHyperSyncServer.takeQueries, page.latestFetchedBlockNumber)
      },
    )

    t.expect((queries, latestFetchedBlockNumber)).toEqual((
      [
        JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 11,
        "include_all_blocks": true,
        "field_selection": {"block": ["hash", "miner", "number", "timestamp"]}
      }`),
      ],
      100,
    ))
  })

  // A chain whose end block is still ahead queries up to it.
  Async.it("bounds a sparse page ending past the head at the known height", async t => {
    let latestFetchedBlockNumber = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [header(10)]})
        let page = await source->fetch(
          ~addressSet,
          ~onBlockRegistrations=named("sparse"),
          ~toBlock=Some(20_000),
        )
        page.latestFetchedBlockNumber
      },
    )

    t.expect(latestFetchedBlockNumber).toEqual(100)
  })

  // At the head every block's hash is kept for reorg detection, so a realtime
  // page reads its whole range even for a sparse handler.
  Async.it("reads every block of a realtime page", async t => {
    let queries = await MockHyperSyncServer.withServer(
      ~height=20_000,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 12, 13]->Array.map(header)})
        let _ = await source->fetch(
          ~addressSet,
          ~onBlockRegistrations=named("sparse"),
          ~knownHeight=20_000,
          ~includeAllBlocks=true,
        )
        server->MockHyperSyncServer.takeQueries
      },
    )

    t.expect(queries).toEqual([
      JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 14,
        "include_all_blocks": true,
        "field_selection": {"block": ["hash", "miner", "number", "timestamp"]}
      }`),
    ])
  })

  // The page's item target counts handler runs; reading every block, the
  // source reads as many blocks as the densest handler needs to reach it.
  Async.it("caps a page reading every block at the blocks its item target needs", async t => {
    let queries = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 12, 13]->Array.map(header)})
        let _ = await source->fetch(~addressSet, ~itemsTarget=Some(2))
        server->MockHyperSyncServer.takeQueries
      },
    )

    t.expect(queries).toEqual([
      JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 14,
        "include_all_blocks": true,
        "max_num_blocks": 4,
        "field_selection": {"block": ["hash", "miner", "number", "timestamp"]}
      }`),
    ])
  })

  Async.it("routes the blocks the handler runs on, with its fields", async t => {
    let blocks = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 12, 13]->Array.map(header)})
        await (await source->fetch(~addressSet))->materializedBlocks
      },
    )

    t.expect(blocks).toEqual([
      (
        "headers",
        10,
        Some({
          number: 10,
          timestamp: 1_700_000_010,
          miner: minerAddress->Address.unsafeFromString,
        }),
      ),
      (
        "headers",
        12,
        Some({
          number: 12,
          timestamp: 1_700_000_012,
          miner: minerAddress->Address.unsafeFromString,
        }),
      ),
    ])
  })

  // HyperSync returns every block of the range when asked to, so a missing one
  // is a bad answer — not a block the handler can skip.
  Async.it("rejects a page missing a block the handler runs on", async t => {
    let error = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({blocks: [10, 11, 13]->Array.map(header)})
        switch await source->fetch(~addressSet) {
        | _ => None
        | exception Source.GetItemsError(FailedGettingItems({retry})) => Some(retry)
        }
      },
    )

    t.expect(error).toEqual(
      Some(
        ImpossibleForTheQuery({
          message: "Source returned invalid data with missing required fields: block",
        }),
      ),
    )
  })
})
