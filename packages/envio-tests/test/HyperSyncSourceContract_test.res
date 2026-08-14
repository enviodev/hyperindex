open Vitest

// Query construction, the request itself, and response decoding all live inside
// the native addon, so a local HyperSync server is the only place a test can see
// what the source asks HyperSync for and control what comes back.

let tokenAddress = "0x1111111111111111111111111111111111111111"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let approvalSighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
let fromAddress = "0x00000000000000000000000000000000000000aa"
let toAddress = "0x00000000000000000000000000000000000000bb"
let padded = address => "0x000000000000000000000000" ++ address->String.slice(~start=2)
let uint256 = value => "0x" ++ value->Int.toString(~radix=16)->String.padStart(64, "0")
let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")
let parentHash = "0x00000000000000000000000000000000000000000000000000000000000000a9"
let minerAddress = "0x00000000000000000000000000000000000000cc"
let stateRoot = "0x00000000000000000000000000000000000000000000000000000000000000dd"
let transactionHash = "0x00000000000000000000000000000000000000000000000000000000000000ff"

let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
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
)

// Three registrations, each with its own inline selection: two siblings on
// Transfer, one on Approval. One query carries the union of all three.
let onEventRegistrations = {
  HandlerRegister.resetOnEventRegistrations()
  HandlerRegister.startRegistration(~config)
  let handler = %raw(`() => Promise.resolve()`)
  HandlerRegister.setHandler(
    ~contractName="Token",
    ~eventName="Transfer",
    handler,
    ~eventOptions=Some({fields: {block: ["parentHash"], transaction: ["to"]}}),
  )
  HandlerRegister.setHandler(
    ~contractName="Token",
    ~eventName="Transfer",
    handler,
    ~eventOptions=Some({fields: {block: ["miner"], transaction: ["hash", "gasUsed"]}}),
  )
  HandlerRegister.setHandler(
    ~contractName="Token",
    ~eventName="Approval",
    handler,
    ~eventOptions=Some({fields: {block: ["stateRoot"]}}),
  )
  let chainRegistrations: HandlerRegister.chainRegistrations =
    HandlerRegister.finishRegistration(~config)
    ->Utils.Dict.dangerouslyGetNonOption("1")
    ->Option.getOrThrow
  chainRegistrations.onEventRegistrations->(
    Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
  )
}

let makeSource = (~url) => {
  let addressStore = AddressStore.make(
    ~ecosystem=Ecosystem.Evm,
    ~shouldChecksum=false,
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
    onEventRegistrations,
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses: true,
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
      onEventRegistrations: onEventRegistrations->(
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
