open Vitest

// HyperSync filters transaction handlers server-side, one selection per
// handler and never a log table. An RPC has no such filter, so the source
// reads every block of a capped page in full.

let alice = "0x00000000000000000000000000000000000000aa"
let bob = "0x00000000000000000000000000000000000000bb"
let token = "0x1111111111111111111111111111111111111111"
let transferSelector = "0xa9059cbb"

let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-source-contract
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "${token}"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "from-alice",
    where: () => ({ transaction: { from: ["${alice}"] } }),
    fields: { transaction: ["input", "gasUsed"], block: ["miner"] },
  },
  async ({ transaction, block }) => {
    transaction.input;
    transaction.gasUsed;
    block.miner;
  },
);

indexer.onTransaction(
  {
    name: "token-calls",
    where: () => ({ transaction: { to: ["${token}"], sighash: ["${transferSelector}"], status: 1 } }),
  },
  async ({ transaction }) => {
    transaction.hash;
  },
);
`,
  ~registerHandlers=true,
)

let onTransactionRegistrations = () => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    parsed.registrations()->Utils.Dict.dangerouslyGetNonOption("1")->Option.getOrThrow
  chainRegistrations.onTransactionRegistrations
}

let named = name => onTransactionRegistrations()->Array.filter(reg => reg.name === name)

let makeHyperSyncSource = (~url, ~lowercaseAddresses=true) => {
  let addressStore = TestAddresses.storeOf(~contracts=[], ~addresses=[])
  let source = EvmHyperSyncSource.make({
    chainId: 1->ChainId.fromInt,
    endpointUrl: url,
    onEventRegistrations: [],
    onTransactionRegistrations: onTransactionRegistrations(),
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses,
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
  ~onTransactionRegistrations=onTransactionRegistrations(),
  ~fromBlock=10,
  ~toBlock=Some(13),
  ~knownHeight=100,
  ~itemsTarget=None,
) =>
  source.getItemsOrThrow(
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~reorgableFrom=None,
    ~knownHeight,
    ~partitionId="0",
    ~selection=FetchState.makeSelection(
      ~dependsOnAddresses=false,
      ~onEventRegistrations=[],
      ~onTransactionRegistrations,
    ),
    ~itemsTarget,
    ~retry=0,
    ~logger=Logger.makeInMemory()->Logger.withFields({"test": "onTransaction source contract"}),
  )

let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")
let header = number =>
  JSON.parseOrThrow(
    `{"number":${number->Int.toString},"timestamp":${(1_700_000_000 + number)
        ->Int.toString},"hash":"${blockHash(number)}","miner":"${bob}"}`,
  )
let txHash = (number, index) =>
  "0x" ++
  (number->Int.toString(~radix=16) ++ index->Int.toString(~radix=16))->String.padStart(64, "c")
let transaction = (~number, ~index, ~from, ~to, ~input="0x", ~status=1, ()) =>
  JSON.parseOrThrow(
    `{"block_number":${number->Int.toString},"transaction_index":${index->Int.toString},"hash":"${txHash(
        number,
        index,
      )}","from":"${from}","to":"${to}","input":"${input}","status":${status->Int.toString},"gas_used":21000}`,
  )

type transactionView = {
  transactionIndex: int,
  hash: string,
  from: string,
  to: string,
  input?: string,
  gasUsed?: bigint,
}
type blockView = {number: int, timestamp: int, hash: string, miner?: string}

// What a transaction handler runs with, once the page's transactions and
// blocks are materialised.
let materialized = async (page: Source.blockRangeFetchResponse) => {
  await ChainState.materializePageItems(
    ~items=page.parsedQueueItems,
    ~transactionStore=page.transactionStore->Option.getOrThrow,
    ~blockStore=page.blockStore,
    ~shouldChecksum=false,
  )
  page.parsedQueueItems->Array.map(item =>
    switch item {
    | Internal.Transaction({
        onTransactionRegistration,
        blockNumber,
        transactionIndex,
        ?transaction,
        ?block,
      }) => (
        onTransactionRegistration.name,
        blockNumber,
        transactionIndex,
        transaction->Option.map(tx =>
          tx->(Utils.magic: Internal.eventTransaction => transactionView)
        ),
        block->Option.map(block => block->(Utils.magic: Internal.eventBlock => blockView)),
      )
    | Internal.Event(_) | Internal.Block(_) =>
      JsError.throwWithMessage("Expected a transaction item")
    }
  )
}

describe("A transaction handler, fetched from HyperSync", () => {
  // One selection per handler, the keys the handlers are routed and
  // materialised by, the selector and status the filters route on, the
  // fields they selected, and no log table at all.
  Async.it("asks for the transactions each handler's filter matches", async t => {
    let queries = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        let _ = await source->fetch(~addressSet, ~itemsTarget=Some(500))
        server->MockHyperSyncServer.takeQueries
      },
    )

    t.expect(queries).toEqual([
      JSON.parseOrThrow(
        `{
        "from_block": 10,
        "to_block": 14,
        "transactions": [
          {"from": ["${alice}"]},
          {"to": ["${token}"], "sighash": ["${transferSelector}"], "status": 1}
        ],
        "max_num_transactions": 500,
        "field_selection": {
          "block": ["hash", "miner", "number", "timestamp"],
          "transaction": ["block_number", "from", "gas_used", "hash", "input", "sighash", "status", "to", "transaction_index"]
        }
      }`,
      ),
    ])
  })

  // The server answers with the selected fields alone, so what a filter routes
  // on is asked for whether or not a handler reads it: here the selector and
  // the status, with no handler selecting the calldata or the receipt.
  Async.it("routes on the selector and status it asked for alongside the keys", async t => {
    let (query, items) = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({
          blocks: [header(10)],
          transactions: [
            transaction(~number=10, ~index=3, ~from=bob, ~to=token, ~input=transferSelector, ()),
            transaction(
              ~number=10,
              ~index=4,
              ~from=bob,
              ~to=token,
              ~input=transferSelector,
              ~status=0,
              (),
            ),
          ],
        })
        let items = await (
          await source->fetch(~addressSet, ~onTransactionRegistrations=named("token-calls"))
        )->materialized
        let query =
          server
          ->MockHyperSyncServer.takeQueries
          ->Array.getUnsafe(0)
          ->JSON.Decode.object
          ->Option.getOrThrow
          ->Dict.getUnsafe("field_selection")
        (query, items)
      },
    )

    t.expect((query, items)).toEqual((
      JSON.parseOrThrow(`{
        "block": ["hash", "number", "timestamp"],
        "transaction": ["block_number", "from", "hash", "sighash", "status", "to", "transaction_index"]
      }`),
      [
        (
          "token-calls",
          10,
          3,
          Some({transactionIndex: 3, hash: txHash(10, 3), from: bob, to: token}),
          Some({number: 10, timestamp: 1_700_000_010, hash: blockHash(10)}),
        ),
      ],
    ))
  })

  // The server returns a transaction once however many filters it matched.
  // Handlers sharing one share its row, so each sees the union of their
  // fields, as two event handlers on one transaction do.
  Async.it("routes each transaction to the handlers it matches, with their fields", async t => {
    let items = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({
          blocks: [header(10), header(12)],
          transactions: [
            transaction(~number=10, ~index=3, ~from=alice, ~to=token, ~input=transferSelector, ()),
            transaction(~number=12, ~index=0, ~from=bob, ~to=token, ~input=transferSelector, ()),
            // Matches no handler: a transfer that reverted, from someone else.
            transaction(
              ~number=12,
              ~index=1,
              ~from=bob,
              ~to=token,
              ~input=transferSelector,
              ~status=0,
              (),
            ),
          ],
        })
        await (await source->fetch(~addressSet))->materialized
      },
    )

    let shared = {
      transactionIndex: 3,
      hash: txHash(10, 3),
      from: alice,
      to: token,
      input: transferSelector,
      gasUsed: 21000n,
    }
    let sharedBlock = {number: 10, timestamp: 1_700_000_010, hash: blockHash(10), miner: bob}
    t.expect(items).toEqual([
      ("from-alice", 10, 3, Some(shared), Some(sharedBlock)),
      ("token-calls", 10, 3, Some(shared), Some(sharedBlock)),
      (
        "token-calls",
        12,
        0,
        Some({transactionIndex: 0, hash: txHash(12, 0), from: bob, to: token}),
        Some({number: 12, timestamp: 1_700_000_012, hash: blockHash(12)}),
      ),
    ])
  })

  // A chain keeping checksummed addresses hands them to the handler that way,
  // as to an event handler; routing matched on the bytes either way.
  Async.it("hands the handler checksummed addresses when the chain keeps them", async t => {
    let items = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(
          ~url=server->MockHyperSyncServer.url,
          ~lowercaseAddresses=false,
        )
        server->MockHyperSyncServer.pushResponse({
          blocks: [header(10)],
          transactions: [transaction(~number=10, ~index=0, ~from=alice, ~to=token, ())],
        })
        let page = await source->fetch(~addressSet, ~onTransactionRegistrations=named("from-alice"))
        await ChainState.materializePageItems(
          ~items=page.parsedQueueItems,
          ~transactionStore=page.transactionStore->Option.getOrThrow,
          ~blockStore=page.blockStore,
          ~shouldChecksum=true,
        )
        page.parsedQueueItems->Array.map(
          item =>
            switch item {
            | Internal.Transaction({transaction: ?Some(transaction)}) =>
              let view = transaction->(Utils.magic: Internal.eventTransaction => transactionView)
              (view.from, view.to)
            | _ => JsError.throwWithMessage("Expected a materialised transaction item")
            },
        )
      },
    )

    t.expect(items).toEqual([("0x00000000000000000000000000000000000000AA", token)])
  })

  // The handlers read the transaction's keys unconditionally, so a row the
  // server returned without them is a bad answer rather than a transaction
  // without a sender.
  Async.it("rejects a page missing a field a handler reads", async t => {
    let error = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeHyperSyncSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse({
          blocks: [header(10)],
          transactions: [
            JSON.parseOrThrow(
              `{"block_number":10,"transaction_index":0,"from":"${alice}","to":"${token}","status":1}`,
            ),
          ],
        })
        switch await source->fetch(~addressSet) {
        | _ => None
        | exception Source.GetItemsError(FailedGettingItems({retry})) => Some(retry)
        }
      },
    )

    t.expect(error).toEqual(
      Some(
        ImpossibleForTheQuery({
          message: "Source returned invalid data with missing required fields: transaction.hash, transaction.input, transaction.gasUsed",
        }),
      ),
    )
  })
})

let makeRpcSource = (~url) => {
  let addressStore = TestAddresses.storeOf(~contracts=[], ~addresses=[])
  let source = RpcSource.make({
    url,
    chainId: 1->ChainId.fromInt,
    onEventRegistrations: [],
    onTransactionRegistrations: onTransactionRegistrations(),
    sourceFor: Sync,
    syncConfig: EvmChain.getSyncConfig({
      initialBlockInterval: 1000,
      intervalCeiling: 1000,
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

let hex = n => "0x" ++ n->Int.toString(~radix=16)

let rpcTransaction = (~number, ~index, ~from, ~to, ~input="0x", ()) =>
  JSON.parseOrThrow(
    `{"hash":"${txHash(number, index)}","blockNumber":"${hex(number)}","blockHash":"${blockHash(
        number,
      )}","transactionIndex":"${hex(
        index,
      )}","from":"${from}","to":"${to}","input":"${input}","value":"0x0","nonce":"0x0","gas":"0x5208","gasPrice":"0x1","type":"0x2"}`,
  )

let rpcBlock = (number, ~transactions) =>
  JSON.parseOrThrow(
    `{"number":"${hex(number)}","timestamp":"${hex(1_700_000_000 + number)}","hash":"${blockHash(
        number,
      )}","parentHash":"${blockHash(number - 1)}","miner":"${bob}","transactions":[${transactions
      ->Array.map(tx => JSON.stringify(tx))
      ->Array.join(",")}]}`,
  )

let receipt = (~number, ~index, ~status) =>
  JSON.parseOrThrow(
    `{"transactionHash":"${txHash(number, index)}","blockNumber":"${hex(
        number,
      )}","transactionIndex":"${hex(index)}","status":"${hex(
        status,
      )}","gasUsed":"0x5208","cumulativeGasUsed":"0x5208","effectiveGasPrice":"0x1"}`,
  )

let fullBlockCall = (number, ~transactions) =>
  MockRpcServer.expectCall(
    ~label=`block ${number->Int.toString} in full`,
    ~method="eth_getBlockByNumber",
    ~params=JSON.parseOrThrow(`["${hex(number)}",true]`),
    ~reply=RpcResult(rpcBlock(number, ~transactions)),
  )

let receiptCall = (~number, ~index, ~status) =>
  MockRpcServer.expectCall(
    ~label=`receipt ${number->Int.toString}:${index->Int.toString}`,
    ~method="eth_getTransactionReceipt",
    ~params=JSON.parseOrThrow(`["${txHash(number, index)}"]`),
    ~reply=RpcResult(receipt(~number, ~index, ~status)),
  )

describe("A transaction handler, fetched from an RPC", () => {
  // Every block is read in full, no log is asked for, nothing is read by hash,
  // and a receipt only where the status is filtered on or a receipt field was
  // selected (`gasUsed` here).
  Async.it("reads every block in full and routes the transactions client-side", async t => {
    let items = await MockRpcServer.withScenario(
      ~name="transaction handler page",
      ~calls=[
        fullBlockCall(
          10,
          ~transactions=[
            rpcTransaction(~number=10, ~index=0, ~from=alice, ~to=bob, ()),
            rpcTransaction(~number=10, ~index=1, ~from=bob, ~to=token, ~input=transferSelector, ()),
          ],
        ),
        fullBlockCall(11, ~transactions=[]),
        fullBlockCall(
          12,
          ~transactions=[rpcTransaction(~number=12, ~index=0, ~from=bob, ~to=alice, ())],
        ),
        fullBlockCall(
          13,
          ~transactions=[
            rpcTransaction(
              ~number=13,
              ~index=0,
              ~from=alice,
              ~to=token,
              ~input=transferSelector,
              (),
            ),
          ],
        ),
        receiptCall(~number=10, ~index=0, ~status=1),
        receiptCall(~number=10, ~index=1, ~status=0),
        receiptCall(~number=13, ~index=0, ~status=1),
      ],
      async mock => {
        let (source, addressSet) = makeRpcSource(~url=mock.url)
        await (await source->fetch(~addressSet))->materialized
      },
    )

    let shared = {
      transactionIndex: 0,
      hash: txHash(13, 0),
      from: alice,
      to: token,
      input: transferSelector,
      gasUsed: 21000n,
    }
    let sharedBlock = {number: 13, timestamp: 1_700_000_013, hash: blockHash(13), miner: bob}
    t.expect(items).toEqual([
      (
        "from-alice",
        10,
        0,
        Some({
          transactionIndex: 0,
          hash: txHash(10, 0),
          from: alice,
          to: bob,
          input: "0x",
          gasUsed: 21000n,
        }),
        Some({number: 10, timestamp: 1_700_000_010, hash: blockHash(10), miner: bob}),
      ),
      ("from-alice", 13, 0, Some(shared), Some(sharedBlock)),
      ("token-calls", 13, 0, Some(shared), Some(sharedBlock)),
    ])
  })

  // Each block costs a request, so a page reads at most a hundred of them
  // however wide the partition's interval has grown.
  Async.it("caps a page at the blocks it can afford to read in full", async t => {
    let latestFetchedBlockNumber = await MockRpcServer.withScenario(
      ~name="transaction handler page cap",
      ~calls=Array.fromInitializer(~length=100, i => fullBlockCall(10 + i, ~transactions=[])),
      async mock => {
        let (source, addressSet) = makeRpcSource(~url=mock.url)
        let page = await source->fetch(
          ~addressSet,
          ~toBlock=Some(1_000),
          ~knownHeight=1_000,
          ~onTransactionRegistrations=named("from-alice"),
        )
        page.latestFetchedBlockNumber
      },
    )

    t.expect(latestFetchedBlockNumber).toEqual(109)
  })
})
