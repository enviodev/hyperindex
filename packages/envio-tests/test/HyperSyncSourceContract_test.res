open Vitest

// Query construction, the request itself, and response decoding all live inside
// the native addon, so a local HyperSync server is the only place a test can see
// what the source asks HyperSync for and control what comes back.

let tokenAddress = "0x1111111111111111111111111111111111111111"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let approvalSighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
let fromAddress = "0x00000000000000000000000000000000000000aa"
let toAddress = "0x000000000000000000000000000000000000dead"
let padded = address => "0x000000000000000000000000" ++ address->String.slice(~start=2)
let uint256 = value => "0x" ++ value->Int.toString(~radix=16)->String.padStart(64, "0")
let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")
let parentHash = "0x00000000000000000000000000000000000000000000000000000000000000a9"
let minerAddress = "0x000000000000000000000000000000000000beef"
let stateRoot = "0x00000000000000000000000000000000000000000000000000000000000000dd"
let transactionHash = "0x00000000000000000000000000000000000000000000000000000000000000ff"

let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: hypersync-source-contract
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "${tokenAddress}"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  // Three registrations, each with its own inline selection: two siblings on
  // Transfer, one on Approval. One query carries the union of all three.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { block: ["parentHash"], transaction: ["to"] } },
  async ({ event }) => {
    event.block.parentHash;
    event.transaction.to;
  },
);

indexer.onEvent(
  {
    contract: "Token",
    event: "Transfer",
    fields: { block: ["miner"], transaction: ["hash", "gasUsed"] },
  },
  async ({ event }) => {
    event.block.miner;
    event.transaction.hash;
    event.transaction.gasUsed;
  },
);

indexer.onEvent(
  { contract: "Token", event: "Approval", fields: { block: ["stateRoot"] } },
  async ({ event }) => {
    event.block.stateRoot;
  },
);
`,
  ~registerHandlers=true,
)

let onEventRegistrations = () => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    parsed.registrations()->Utils.Dict.dangerouslyGetNonOption("1")->Option.getOrThrow
  chainRegistrations.onEventRegistrations->(
    Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
  )
}

let makeSource = (~url, ~lowercaseAddresses=true) => {
  let addressStore = AddressStore.make(
    ~ecosystem=Ecosystem.Evm,
    ~shouldChecksum=!lowercaseAddresses,
    ~contracts=[{name: "Token", startBlock: None, dependsOnAddresses: true}],
  )
  let _ = addressStore->AddressStore.seedBatch([
    {
      address: tokenAddress->Address.unsafeFromString,
      contractName: "Token",
      registrationBlock: -1,
    },
  ])
  let source = EvmHyperSyncSource.make({
    chainId: 1->ChainId.fromInt,
    endpointUrl: url,
    onEventRegistrations: onEventRegistrations(),
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses,
    serializationFormat: Json,
    enableQueryCaching: false,
    logLevel: #error,
    addressStore,
  })
  (source, addressStore->AddressStore.makeSet(~contractName="Token"))
}

let fetch = (source: Source.t, ~addressSet, ~fromBlock=10, ~toBlock=Some(11)) =>
  source.getItemsOrThrow(
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~knownHeight=100,
    ~partitionId="mock-partition",
    ~selection={
      dependsOnAddresses: true,
      onEventRegistrations: onEventRegistrations()->(
        Utils.magic: array<Internal.evmOnEventRegistration> => array<Internal.onEventRegistration>
      ),
    },
    ~itemsTarget=Some(5_000),
    ~retry=0,
    ~logger=Logging.createChild(~params={"test": "HyperSync source contract"}),
  )

// A Transfer in block 10 and an Approval in block 11, each with its own
// transaction. Only fields the query selected are read back off these rows.
let page: MockHyperSyncServer.page = {
  blocks: [
    JSON.parseOrThrow(
      `{"number":10,"timestamp":1700000000,"hash":"${blockHash(10)}","parent_hash":"${parentHash}","miner":"${minerAddress}","state_root":"${stateRoot}"}`,
    ),
    JSON.parseOrThrow(
      `{"number":11,"timestamp":1700000012,"hash":"${blockHash(11)}","parent_hash":"${blockHash(
          10,
        )}","miner":"${minerAddress}","state_root":"${stateRoot}"}`,
    ),
  ],
  transactions: [
    JSON.parseOrThrow(
      `{"block_number":10,"transaction_index":3,"hash":"${transactionHash}","to":"${toAddress}","gas_used":21000}`,
    ),
    JSON.parseOrThrow(
      `{"block_number":11,"transaction_index":0,"hash":"${transactionHash}","to":"${toAddress}","gas_used":30000}`,
    ),
  ],
  logs: [
    JSON.parseOrThrow(
      `{"block_number":10,"log_index":7,"transaction_index":3,"address":"${tokenAddress}","data":"${uint256(
          100,
        )}","topic0":"${transferSighash}","topic1":"${fromAddress->padded}","topic2":"${toAddress->padded}"}`,
    ),
    JSON.parseOrThrow(
      `{"block_number":11,"log_index":0,"transaction_index":0,"address":"${tokenAddress}","data":"${uint256(
          5,
        )}","topic0":"${approvalSighash}","topic1":"${fromAddress->padded}","topic2":"${toAddress->padded}"}`,
    ),
  ],
}

type paramsView = {
  from?: Address.t,
  to?: Address.t,
  owner?: Address.t,
  spender?: Address.t,
  value: bigint,
}
type blockView = {number: int, parentHash?: string, miner?: Address.t, stateRoot?: string}
type transactionView = {hash?: string, to?: Address.t, gasUsed?: bigint}

let eventSummary = (item: Internal.item) =>
  switch item {
  | Internal.Event(event) => {
      let payload = event.payload->Evm.toPayload
      {
        "registrationIndex": event.onEventRegistration.index,
        "eventName": payload.eventName,
        "blockNumber": event.blockNumber,
        "logIndex": event.logIndex,
        "transactionIndex": event.transactionIndex,
        "srcAddress": payload.srcAddress->Address.toString,
        "params": payload.params->(Utils.magic: Internal.eventParams => paramsView),
        "block": event.payload
        ->Internal.getPayloadBlock
        ->Nullable.toOption
        ->Option.getOrThrow
        ->(Utils.magic: Internal.eventBlock => blockView),
        "transaction": event.payload
        ->Internal.getPayloadTransaction
        ->Nullable.toOption
        ->Option.getOrThrow
        ->(Utils.magic: Internal.eventTransaction => transactionView),
      }
    }
  | Internal.Block(_) => JsError.throwWithMessage("Expected an event item")
  }

describe("HyperSync source contract", () => {
  Async.it("sends one query carrying every registration's selection", async t => {
    let queries = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse(page)
      let _ = await source->fetch(~addressSet)
      server->MockHyperSyncServer.takeQueries
    })

    t.expect(queries).toEqual([
      JSON.parseOrThrow(`{
        "from_block": 10,
        "to_block": 12,
        "logs": [
          {
            "address": ["${tokenAddress}"],
            "topics": [["${transferSighash}", "${approvalSighash}"], [], [], []]
          }
        ],
        "field_selection": {
          "block": ["hash", "miner", "number", "parent_hash", "state_root", "timestamp"],
          "transaction": ["block_number", "gas_used", "hash", "to", "transaction_index"],
          "log": [
            "address",
            "block_number",
            "data",
            "log_index",
            "topic0",
            "topic1",
            "topic2",
            "topic3",
            "transaction_index"
          ]
        },
        "max_num_logs": 5000
      }`),
    ])
  })

  Async.it("materialises the selected fields onto the page's items", async t => {
    let items = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse(page)
      let page = await source->fetch(~addressSet)
      await ChainState.materializePageItems(
        ~items=page.parsedQueueItems,
        ~transactionStore=page.transactionStore,
        ~blockStore=page.blockStore,
      )
      page.parsedQueueItems
    })

    // The Approval item shows the selection is per (block, transaction) group,
    // not per page: it gets its own registration's `stateRoot` and none of the
    // Transfer fields. The two Transfer siblings share one block and one
    // transaction object, so they share the union of their two selections —
    // each still reads only what it declared.
    t.expect(items->Array.map(eventSummary)).toEqual([
      {
        "registrationIndex": 0,
        "eventName": "Transfer",
        "blockNumber": 10,
        "logIndex": 7,
        "transactionIndex": 3,
        "srcAddress": tokenAddress,
        "params": {
          from: fromAddress->Address.unsafeFromString,
          to: toAddress->Address.unsafeFromString,
          value: 100n,
        },
        "block": {number: 10, parentHash, miner: minerAddress->Address.unsafeFromString},
        "transaction": {
          hash: transactionHash,
          to: toAddress->Address.unsafeFromString,
          gasUsed: 21000n,
        },
      },
      {
        "registrationIndex": 1,
        "eventName": "Transfer",
        "blockNumber": 10,
        "logIndex": 7,
        "transactionIndex": 3,
        "srcAddress": tokenAddress,
        "params": {
          from: fromAddress->Address.unsafeFromString,
          to: toAddress->Address.unsafeFromString,
          value: 100n,
        },
        "block": {number: 10, parentHash, miner: minerAddress->Address.unsafeFromString},
        "transaction": {
          hash: transactionHash,
          to: toAddress->Address.unsafeFromString,
          gasUsed: 21000n,
        },
      },
      {
        "registrationIndex": 2,
        "eventName": "Approval",
        "blockNumber": 11,
        "logIndex": 0,
        "transactionIndex": 0,
        "srcAddress": tokenAddress,
        "params": {
          owner: fromAddress->Address.unsafeFromString,
          spender: toAddress->Address.unsafeFromString,
          value: 5n,
        },
        "block": {number: 11, stateRoot},
        "transaction": ({}: transactionView),
      },
    ])
  })

  Async.it("reads the height off the server", async t => {
    let height = await MockHyperSyncServer.withServer(~height=42, async server => {
      let (source, _) = makeSource(~url=server->MockHyperSyncServer.url)
      let {height} = await source.getHeightOrThrow()
      height
    })
    t.expect(height).toBe(42)
  })

  Async.it("keeps the rollback guard's blocks in the page store", async t => {
    let missingHashes = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({
        ...page,
        rollbackGuard: JSON.parseOrThrow(
          `{"blockNumber":20,"timestamp":1700000100,"hash":"${blockHash(
              20,
            )}","firstBlockNumber":10,"firstParentHash":"${blockHash(9)}"}`,
        ),
      })
      let page = await source->fetch(~addressSet)
      // The guard's head block and the parent of the range's first block are
      // reorg-detection inputs, so they come back hashed alongside the range.
      page.blockStore->BlockStore.missingHashes([9, 10, 20, 21])
    })

    t.expect(missingHashes).toEqual([21])
  })

  Async.it("receives heights pushed over the height stream", async t => {
    let heights = await MockHyperSyncServer.withServer(~height=7, async server => {
      let (source, _) = makeSource(~url=server->MockHyperSyncServer.url)
      let heights = []
      let subscribe =
        source.createHeightSubscription->Option.getOrThrow(
          ~message="HyperSync source must push heights",
        )
      let unsubscribe = subscribe(~onHeight=height => heights->Array.push(height)->ignore)
      while heights->Array.length < 1 {
        await Utils.delay(10)
      }
      server->MockHyperSyncServer.setHeight(9)
      while heights->Array.length < 2 {
        await Utils.delay(10)
      }
      unsubscribe()
      heights
    })

    t.expect(heights).toEqual([7, 9])
  })

  Async.it("surfaces a page that withholds a selected field", async t => {
    let result = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({
        ...page,
        // The query asked for `gas_used`; this page answers without it.
        transactions: [
          JSON.parseOrThrow(
            `{"block_number":10,"transaction_index":3,"hash":"${transactionHash}","to":"${toAddress}"}`,
          ),
          JSON.parseOrThrow(
            `{"block_number":11,"transaction_index":0,"hash":"${transactionHash}","to":"${toAddress}"}`,
          ),
        ],
      })
      try {
        let _ = await source->fetch(~addressSet)
        "no error"
      } catch {
      | Source.GetItemsError(FailedGettingItems({retry: ImpossibleForTheQuery({message})})) => message
      }
    })

    t.expect(result).toBe(
      "Source returned invalid data with missing required fields: transaction.gasUsed",
    )
  })
})

let failureTag = exn =>
  switch exn {
  | Source.RateLimited({resetMs}) => `rateLimited:${resetMs->Int.toString}`
  | Source.SourceBehindHead({blockNumber}) => `behindHead:${blockNumber->Int.toString}`
  | Source.GetItemsError(FailedGettingItems({retry: ImpossibleForTheQuery({message})})) =>
    `impossible:${message}`
  | Source.GetItemsError(FailedGettingItems({retry: WithBackoff({message})})) => `backoff:${message}`
  | JsExn(jsExn) => `exn:${jsExn->JsExn.message->Option.getOr("")}`
  | _ => "unknown"
  }

let attempt = async body =>
  switch await body() {
  | value => `ok:${value}`
  | exception exn => failureTag(exn)
  }

describe("HyperSync source responses", () => {
  Async.it("maps a rate-limited response to the wait the manager retries on", async t => {
    let result = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushRawReply({
        status: 429,
        headers: Dict.fromArray([("x-ratelimit-reset", "3"), ("x-ratelimit-remaining", "0")]),
        body: "slow down",
      })
      await attempt(async () => {
        let _ = await source->fetch(~addressSet)
        "fetched"
      })
    })
    t.expect(result).toBe("rateLimited:3000")
  })

  Async.it("reads a page that made no progress as the instance being behind head", async t => {
    let result = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({nextBlock: 10})
      await attempt(async () => {
        let _ = await source->fetch(~addressSet)
        "fetched"
      })
    })
    t.expect(result).toBe("behindHead:10")
  })

  Async.it("reports the range a partial page actually covered", async t => {
    let summary = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({...page, nextBlock: 11, archiveHeight: 60})
      let response = await source->fetch(~addressSet, ~fromBlock=10, ~toBlock=Some(11))
      {
        "latestFetchedBlockNumber": response.latestFetchedBlockNumber,
        "knownHeight": response.knownHeight,
        "items": response.parsedQueueItems->Array.length,
      }
    })
    t.expect(summary).toEqual({
      "latestFetchedBlockNumber": 10,
      "knownHeight": 60,
      "items": 3,
    })
  })

  Async.it("lets the client halve the range on a payload-too-large reply", async t => {
    let (result, queries) = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushRawReply({status: 413})
      server->MockHyperSyncServer.pushResponse({nextBlock: 26})
      let result = await attempt(async () => {
        let response = await source->fetch(~addressSet, ~fromBlock=10, ~toBlock=Some(41))
        response.latestFetchedBlockNumber->Int.toString
      })
      (
        result,
        server
        ->MockHyperSyncServer.takeQueries
        ->Array.map(query =>
          query
          ->JSON.Decode.object
          ->Option.flatMap(o => o->Dict.get("to_block"))
          ->Option.flatMap(JSON.Decode.float)
        ),
      )
    })
    t.expect((result, queries)).toEqual(("ok:25", [Some(42.), Some(26.)]))
  })

  Async.it("drops logs that route to no registration", async t => {
    let counts = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({
        ...page,
        logs: [
          // An event neither registration declared.
          JSON.parseOrThrow(
            `{"block_number":10,"log_index":1,"transaction_index":3,"address":"${tokenAddress}","data":"0x","topic0":"${blockHash(
                1,
              )}"}`,
          ),
          // The right event, from an address the partition never registered.
          JSON.parseOrThrow(
            `{"block_number":10,"log_index":2,"transaction_index":3,"address":"${minerAddress}","data":"${uint256(
                1,
              )}","topic0":"${transferSighash}","topic1":"${fromAddress->padded}","topic2":"${toAddress->padded}"}`,
          ),
        ],
      })
      let response = await source->fetch(~addressSet)
      response.parsedQueueItems->Array.length
    })
    t.expect(counts).toBe(0)
  })

  Async.it("checksums addresses when the chain does not lowercase them", async t => {
    let summary = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(
        ~url=server->MockHyperSyncServer.url,
        ~lowercaseAddresses=false,
      )
      server->MockHyperSyncServer.pushResponse(page)
      let response = await source->fetch(~addressSet)
      await ChainState.materializePageItems(
        ~items=response.parsedQueueItems,
        ~transactionStore=response.transactionStore,
        ~blockStore=response.blockStore,
      )
      let summary = response.parsedQueueItems->Array.map(eventSummary)->Array.getUnsafe(0)
      {
        "param": summary["params"].to->Option.getOrThrow->Address.toString,
        "transaction": summary["transaction"].to->Option.getOrThrow->Address.toString,
        "miner": summary["block"].miner->Option.getOrThrow->Address.toString,
      }
    })
    // Checksummed on the way out of the client, from the same lowercase rows
    // the other tests read back verbatim.
    t.expect(summary).toEqual({
      "param": "0x000000000000000000000000000000000000dEaD",
      "transaction": "0x000000000000000000000000000000000000dEaD",
      "miner": "0x000000000000000000000000000000000000bEEF",
    })
  })

  // Reorg rollback is the only caller of this path, and it went through a
  // detached napi method reference until this test called it.
  Async.it("paginates the block-hash query", async t => {
    let queries = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, _) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({
        blocks: [JSON.parseOrThrow(`{"number":10,"hash":"${blockHash(10)}"}`)],
        nextBlock: 11,
      })
      server->MockHyperSyncServer.pushResponse({
        blocks: [
          JSON.parseOrThrow(`{"number":10,"hash":"${blockHash(10)}"}`),
          JSON.parseOrThrow(`{"number":11,"hash":"${blockHash(11)}"}`),
          JSON.parseOrThrow(`{"number":12,"hash":"${blockHash(12)}"}`),
        ],
        nextBlock: 13,
      })
      let {result} =
        await source.getBlockHashes(
          ~blockNumbers=[10, 12],
          ~logger=Logging.createChild(~params={"test": "block hashes"}),
        )
      let missing = switch result {
      | Ok(store) => store->BlockStore.missingHashes([10, 11, 12, 13])->Array.map(n => n->Int.toString)
      | Error(exn) => [failureTag(exn)]
      }
      (server->MockHyperSyncServer.takeQueries, missing)
    })
    t.expect(queries).toEqual((
      [
        JSON.parseOrThrow(
          `{"from_block":10,"to_block":13,"include_all_blocks":true,"field_selection":{"block":["hash","number"]}}`,
        ),
        JSON.parseOrThrow(
          `{"from_block":10,"to_block":13,"include_all_blocks":true,"field_selection":{"block":["hash","number"]}}`,
        ),
      ],
      ["13"],
    ))
  })

  Async.it("surfaces a page that withholds a selected block field", async t => {
    let result = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse({
        ...page,
        blocks: [
          JSON.parseOrThrow(
            `{"number":10,"timestamp":1700000000,"hash":"${blockHash(10)}","parent_hash":"${parentHash}","state_root":"${stateRoot}"}`,
          ),
          JSON.parseOrThrow(
            `{"number":11,"timestamp":1700000012,"hash":"${blockHash(
                11,
              )}","parent_hash":"${blockHash(10)}","state_root":"${stateRoot}"}`,
          ),
        ],
      })
      await attempt(async () => {
        let _ = await source->fetch(~addressSet)
        "fetched"
      })
    })
    t.expect(result).toBe(
      "impossible:Source returned invalid data with missing required fields: block.miner",
    )
  })
})
