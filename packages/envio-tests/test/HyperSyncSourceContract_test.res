open Vitest

// The HyperSync source as a user runs it: a config.yaml naming a local
// HyperSync server, handlers with their own field selections, and the rows they
// write. Query construction, the request and response decoding all live in the
// native addon, so the server's query log is where a test sees what the source
// asked for, and the pages queued on it are what comes back. Each scenario has
// a port of its own, fixed because its config is parsed while vitest collects,
// so a request one run left in flight can't claim a page queued for the next.
let nextPort = ref(18661)

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

let blockRow = (~number, ~timestamp, ~parent, ~miner=true) =>
  JSON.parseOrThrow(
    `{"number":${number->Int.toString},"timestamp":${timestamp->Int.toString},"hash":"${blockHash(
        number,
      )}","parent_hash":"${parent}"${miner
        ? `,"miner":"${minerAddress}"`
        : ""},"state_root":"${stateRoot}"}`,
  )

// A Transfer in block 10 and an Approval in block 11, each with its own
// transaction.
let page: MockHyperSyncServer.page = {
  blocks: [
    blockRow(~number=10, ~timestamp=1700000000, ~parent=parentHash),
    blockRow(~number=11, ~timestamp=1700000012, ~parent=blockHash(10)),
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
let blockTwelve = blockRow(~number=12, ~timestamp=1700000024, ~parent=blockHash(11))

let serverHeight = 100
// A fresh server per run: a reply queued for one run and left unclaimed would
// otherwise answer the next run's first query.
let server = ref(None)
let closeServer = () =>
  switch server.contents {
  | Some(running) =>
    running->MockHyperSyncServer.close
    server := None
  | None => ()
  }
Async.afterAll(async () => closeServer())
let hyperSync = () =>
  server.contents->Option.getOrThrow(~message="the HyperSync server never started")

type chain = {scenario: Scenario.t, port: int}

// Starts `chain`'s server at `height`, with `replies` queued for its first
// queries.
let serve = (chain, ~height=serverHeight, replies: array<MockHyperSyncServer.page>) => {
  closeServer()
  let started = MockHyperSyncServer.make(~height, ~port=chain.port)
  replies->Array.forEach(reply => started->MockHyperSyncServer.pushResponse(reply))
  server := Some(started)
}

let schema = `
type Seen {
  id: ID!
  log: String!
  block: String!
  transaction: String!
  params: String!
}
`

// Three registrations, each with its own inline selection: two siblings on
// Transfer, one on Approval. Each writes everything it was handed, so a field
// it was given without selecting it shows up too.
let handlers = `
import { indexer } from "envio";

const show = (value: object) =>
  JSON.stringify(value, (_key, field) =>
    typeof field === "bigint" ? \`\${field}n\` : field === undefined ? "undefined" : field,
  );

const record =
  (registration: string) =>
  async ({ event, context }: { event: any; context: any }) => {
    context.Seen.set({
      id: \`\${registration}-\${event.block.number}-\${event.logIndex}\`,
      log: show({ srcAddress: event.srcAddress, logIndex: event.logIndex }),
      block: show(event.block),
      transaction: show(event.transaction),
      params: show(event.params),
    });
  };

indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { block: ["parentHash"], transaction: ["to"] } },
  record("first"),
);

indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { block: ["miner"], transaction: ["hash", "gasUsed"] } },
  record("second"),
);

indexer.onEvent(
  { contract: "Token", event: "Approval", fields: { block: ["stateRoot"] } },
  record("approval"),
);
`

let chain = (
  ~startBlock=10,
  ~endBlock=Some(11),
  ~addressFormat="lowercase",
  ~rollbackOnReorg=false,
  ~maxReorgDepth=0,
) => {
  let port = nextPort.contents
  nextPort := port + 1
  let scenario = Scenario.make(
    ~schema,
    ~handlers,
    ~configYaml=`
name: hypersync-source
rollback_on_reorg: ${rollbackOnReorg ? "true" : "false"}
address_format: ${addressFormat}
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1
    start_block: ${startBlock->Int.toString}${endBlock->Option.mapOr("", endBlock =>
        `\n    end_block: ${endBlock->Int.toString}`
      )}
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    hypersync_config:
      url: http://127.0.0.1:${port->Int.toString}
    contracts:
      - name: Token
        address: "${tokenAddress}"
`,
  )
  {scenario, port}
}

type row = {id: string, log: string, block: string, transaction: string, params: string}

let readRows = async (indexer: IndexerRunner.t) => {
  let rows: array<row> = await indexer.query("Seen")
  rows
  ->Array.toSorted((a, b) => String.compare(a.id, b.id))
  ->Array.map(({id, log, block, transaction, params}) =>
    {
      "id": id,
      "log": log->JSON.parseOrThrow,
      "block": block->JSON.parseOrThrow,
      "transaction": transaction->JSON.parseOrThrow,
      "params": params->JSON.parseOrThrow,
    }
  )
}

let queries = () => hyperSync()->MockHyperSyncServer.takeQueries
let queryField = (query, field) =>
  query->JSON.Decode.object->Option.flatMap(query => query->Dict.get(field))

let metricValues = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.map(({value}) => value)

// Waits for the run to reach its end block or stop on an error, then hands
// `body` the indexer to read from.
let indexToEnd = async (chain, ~whileRunning=?, body) => {
  let exited = ref(false)
  let error = ref(None)
  await chain.scenario->Scenario.run(
    ~yamlSources=true,
    ~onExit=() => exited := true,
    ~onError=failure => error := Some(failure.exn->Utils.exnMessage),
    async (~indexer, ~source as _) => {
      switch whileRunning {
      | Some(step) => await step(indexer)
      | None => ()
      }
      await Scenario.waitUntil(
        () => exited.contents || error.contents->Option.isSome,
        ~message="the run to reach its end block or stop",
      )
      await body(indexer, error.contents->Option.flatMap(message => message))
    },
  )
}

let warnings = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filterMap(line =>
    switch (line->Dict.get("level"), line->Dict.get("msg")) {
    | (Some(String("warn")), Some(String(msg))) => Some(msg)
    | _ => None
    }
  )

// With no other source to ask, the run stops, and names the field only in the
// warning that gave up on the query.
let noSourcesLeft = "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team."

// Waits until a page has failed and been put back to retry, which arms the
// backoff the test then advances through.
let waitForRetry = (indexer: IndexerRunner.t) =>
  Scenario.waitUntil(
    () =>
      indexer.allLogsAsJson()->Array.some(line =>
        line->Dict.get("backOffMilliseconds")->Option.isSome
      ),
    ~message="a page to be retried",
  )

let backfill = chain()
let throughFortyOne = chain(~endBlock=Some(41))

describe("HyperSync queries", () => {
  Async.it("Sends one query carrying every registration's selection", async t => {
    backfill->serve([page])
    await backfill->indexToEnd(
      async (_indexer, error) =>
        t.expect((error, queries()->Array.slice(~start=0, ~end=1))).toEqual((
          None,
          [
            JSON.parseOrThrow(
              `{
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
            "max_num_logs": 10000
          }`,
            ),
          ],
        )),
    )
  })

  // Where blocks can still be reorged, every hash of the range feeds reorg
  // detection, and at the head the progress block is often one no event landed
  // on. Asking for every block puts both in the response.
  let reorgable = chain(~endBlock=None, ~rollbackOnReorg=true, ~maxReorgDepth=200)
  let reorgableAtTwelve = chain(~endBlock=None, ~rollbackOnReorg=true, ~maxReorgDepth=200)
  Async.it("Asks for every block in a range that can still be reorged", async t => {
    reorgable->serve(
      ~height=12,
      [
        {
          ...page,
          blocks: page.blocks->Option.getOrThrow->Array.concat([blockTwelve]),
          nextBlock: 13,
        },
      ],
    )
    await reorgable.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer as _, ~source as _) => {
        let sent = []
        await Scenario.waitUntil(
          () => {
            sent->Array.pushMany(queries())
            sent->Array.length > 0
          },
          ~message="the first query",
        )
        t.expect(
          sent
          ->Array.slice(~start=0, ~end=1)
          ->Array.map(query => query->queryField("include_all_blocks")),
        ).toEqual([Some(JSON.Boolean(true))])
      },
    )
  })

  // The whole point of asking for every block: the one the chain has processed
  // up to usually carries no log, and its timestamp is how far behind chain
  // time the indexer is.
  Async.it("Keeps the time of a block no log came from", async t => {
    reorgableAtTwelve->serve(
      ~height=12,
      [
        {
          ...page,
          blocks: page.blocks->Option.getOrThrow->Array.concat([blockTwelve]),
          nextBlock: 13,
        },
      ],
    )
    await reorgableAtTwelve.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        let deadline = ref(0)
        while (
          (await indexer->metricValues("envio_progress_block_time_seconds")) == [] &&
            deadline.contents < 500
        ) {
          // Real time: the page comes back over a real socket.
          await Utils.delay(10)
          // Progress is written on a throttle, and the metric reads what was
          // written.
          await indexer.advanceTime(500)
          deadline := deadline.contents + 1
        }
        t.expect(await indexer->metricValues("envio_progress_block_time_seconds")).toEqual([
          "1700000024",
        ])
      },
    )
  })

  Async.it("Lets the client halve a range the server found too large", async t => {
    throughFortyOne->serve([])
    let server = hyperSync()
    server->MockHyperSyncServer.pushRawReply({status: 413})
    server->MockHyperSyncServer.pushResponse({nextBlock: 26})
    await throughFortyOne->indexToEnd(
      async (_indexer, error) =>
        t.expect((
          error,
          queries()
          ->Array.slice(~start=0, ~end=2)
          ->Array.map(query => query->queryField("to_block")),
        )).toEqual((None, [Some(JSON.Number(42.)), Some(JSON.Number(26.))])),
    )
  })
})

describe("HyperSync pages", () => {
  // The Approval shows the selection is per (block, transaction) group, not per
  // page: it gets its own registration's `stateRoot` and none of the Transfer
  // fields. The two Transfer siblings share one block and one transaction
  // object, so they are handed the union of their two selections.
  Async.it("Hands each handler the fields selected for its event", async t => {
    backfill->serve([page])
    await backfill->indexToEnd(
      async (indexer, error) => {
        let transfer = (~registration) =>
          {
            "id": `${registration}-10-7`,
            "log": JSON.parseOrThrow(`{"srcAddress":"${tokenAddress}","logIndex":7}`),
            "block": JSON.parseOrThrow(
              `{"number":10,"parentHash":"${parentHash}","miner":"${minerAddress}"}`,
            ),
            "transaction": JSON.parseOrThrow(
              `{"hash":"${transactionHash}","to":"${toAddress}","gasUsed":"21000n"}`,
            ),
            "params": JSON.parseOrThrow(
              `{"from":"${fromAddress}","to":"${toAddress}","value":"100n"}`,
            ),
          }
        t.expect((error, await indexer->readRows)).toEqual((
          None,
          [
            {
              "id": "approval-11-0",
              "log": JSON.parseOrThrow(`{"srcAddress":"${tokenAddress}","logIndex":0}`),
              "block": JSON.parseOrThrow(`{"number":11,"stateRoot":"${stateRoot}"}`),
              "transaction": JSON.parseOrThrow(`{}`),
              "params": JSON.parseOrThrow(
                `{"owner":"${fromAddress}","spender":"${toAddress}","value":"5n"}`,
              ),
            },
            transfer(~registration="first"),
            transfer(~registration="second"),
          ],
        ))
      },
    )
  })

  let checksummed = chain(~addressFormat="checksum")
  Async.it("Checksums addresses when the chain does not lowercase them", async t => {
    checksummed->serve([page])
    await checksummed->indexToEnd(
      async (indexer, _error) => {
        let rows = await indexer->readRows
        let second = rows->Array.find(row => row["id"] === "second-10-7")->Option.getOrThrow
        t.expect((second["params"], second["transaction"], second["block"])).toEqual((
          JSON.parseOrThrow(`{"from":"0x00000000000000000000000000000000000000AA","to":"0x000000000000000000000000000000000000dEaD","value":"100n"}`),
          JSON.parseOrThrow(
            `{"hash":"${transactionHash}","to":"0x000000000000000000000000000000000000dEaD","gasUsed":"21000n"}`,
          ),
          JSON.parseOrThrow(
            `{"number":10,"parentHash":"${parentHash}","miner":"0x000000000000000000000000000000000000bEEF"}`,
          ),
        ))
      },
    )
  })

  Async.it("Drops logs that route to no registration", async t => {
    backfill->serve([
      {
        ...page,
        logs: [
          // An event no registration declared.
          JSON.parseOrThrow(
            `{"block_number":10,"log_index":1,"transaction_index":3,"address":"${tokenAddress}","data":"0x","topic0":"${blockHash(
                1,
              )}"}`,
          ),
          // The right event, from an address the chain never registered.
          JSON.parseOrThrow(
            `{"block_number":10,"log_index":2,"transaction_index":3,"address":"${minerAddress}","data":"${uint256(
                1,
              )}","topic0":"${transferSighash}","topic1":"${fromAddress->padded}","topic2":"${toAddress->padded}"}`,
          ),
        ],
      },
    ])
    await backfill->indexToEnd(
      async (indexer, error) => t.expect((error, await indexer->readRows)).toEqual((None, [])),
    )
  })

  Async.it("Indexes a partial page up to where it reached, and asks for the rest", async t => {
    backfill->serve([{...page, nextBlock: 11, archiveHeight: 60}])
    await backfill->indexToEnd(
      async (indexer, error) => {
        let fromBlocks = queries()->Array.map(query => query->queryField("from_block"))
        t.expect((
          error,
          fromBlocks->Array.slice(~start=0, ~end=2),
          (await indexer->readRows)->Array.map(row => row["id"]),
        )).toEqual((
          None,
          [Some(JSON.Number(10.)), Some(JSON.Number(11.))],
          // Every item on the page is indexed, its Approval in block 11 included,
          // though the page claims to have reached only block 10.
          ["approval-11-0", "first-10-7", "second-10-7"],
        ))
      },
    )
  })

  Async.it("Stops rather than index a page that withholds a selected field", async t => {
    backfill->serve([
      {
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
      },
    ])
    await backfill->indexToEnd(
      async (indexer, error) =>
        t.expect((error, indexer->warnings, await indexer->readRows)).toEqual((
          Some(noSourcesLeft),
          [
            "Source returned invalid data with missing required fields: transaction.gasUsed - Attempting another source",
          ],
          [],
        )),
    )
  })

  Async.it("Stops rather than index a page that withholds a selected block field", async t => {
    backfill->serve([
      {
        ...page,
        blocks: [
          blockRow(~number=10, ~timestamp=1700000000, ~parent=parentHash, ~miner=false),
          blockRow(~number=11, ~timestamp=1700000012, ~parent=blockHash(10), ~miner=false),
        ],
      },
    ])
    await backfill->indexToEnd(
      async (indexer, error) =>
        t.expect((error, indexer->warnings, await indexer->readRows)).toEqual((
          Some(noSourcesLeft),
          [
            "Source returned invalid data with missing required fields: block.miner - Attempting another source",
          ],
          [],
        )),
    )
  })
})

// The guard a page carries names the range's head block and the parent of its
// first block, so the next page's guard can be checked against them. Without
// block 20 kept, a page starting at 21 has nothing to check its parent against.
let guardedChain = chain(~endBlock=None, ~rollbackOnReorg=true, ~maxReorgDepth=200)
describe("HyperSync reorg detection", () => {
  Async.it("Keeps the rollback guard's blocks to check the next page against", async t => {
    guardedChain->serve(
      ~height=30,
      [
        {
          ...page,
          nextBlock: 21,
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":20,"timestamp":1700000100,"hash":"${blockHash(
                20,
              )}","firstBlockNumber":10,"firstParentHash":"${parentHash}"}`,
          ),
        },
        {
          nextBlock: 31,
          // Block 21's parent is not the block 20 the first page reported.
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":30,"timestamp":1700000200,"hash":"${blockHash(
                30,
              )}","firstBlockNumber":21,"firstParentHash":"${blockHash(99)}"}`,
          ),
        },
      ],
    )
    await guardedChain.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        let waited = ref(0)
        while (
          (await indexer->metricValues("envio_reorg_detected_total")) == [] && waited.contents < 500
        ) {
          // Real time: both pages come back over a real socket.
          await Utils.delay(10)
          waited := waited.contents + 1
        }
        t.expect((
          await indexer->metricValues("envio_reorg_detected_total"),
          await indexer->metricValues("envio_reorg_detected_block"),
        )).toEqual((["1"], ["20"]))
      },
    )
  })
})

// The rollback a reorg starts asks for the hashes of the blocks it stored, and
// a server can answer that in pages: the client keeps asking until it has all
// of them, and the rollback lands on the last block whose hash still matches.
let rolledBackChain = chain(~endBlock=None, ~rollbackOnReorg=true, ~maxReorgDepth=200)
let behindRollbackChain = chain(~endBlock=None, ~rollbackOnReorg=true, ~maxReorgDepth=200)
describe("HyperSync rollback", () => {
  Async.it("Pages through the block hashes a rollback asks for", async t => {
    let hashed = numbers =>
      numbers->Array.map(
        number =>
          JSON.parseOrThrow(
            `{"number":${number->Int.toString},"hash":"${number === 9
                ? parentHash
                : blockHash(number)}"}`,
          ),
      )
    rolledBackChain->serve(
      ~height=30,
      [
        {
          ...page,
          nextBlock: 21,
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":20,"timestamp":1700000100,"hash":"${blockHash(
                20,
              )}","firstBlockNumber":10,"firstParentHash":"${parentHash}"}`,
          ),
        },
        {
          nextBlock: 31,
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":30,"timestamp":1700000200,"hash":"${blockHash(
                30,
              )}","firstBlockNumber":21,"firstParentHash":"${blockHash(99)}"}`,
          ),
        },
        // The hashes the rollback asks for, in two pages.
        {blocks: hashed([9, 10]), nextBlock: 11},
        {blocks: hashed([9, 10, 11]), nextBlock: 12},
      ],
    )
    await rolledBackChain.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        let waited = ref(0)
        while (
          (await indexer->metricValues("envio_rollback_total")) != ["1"] && waited.contents < 500
        ) {
          // Real time: every page comes back over a real socket.
          await Utils.delay(10)
          waited := waited.contents + 1
        }
        let hashQueries = queries()->Array.filter(
          query =>
            query
            ->queryField("field_selection")
            ->Option.flatMap(JSON.Decode.object)
            ->Option.mapOr(false, selection => selection->Dict.get("log")->Option.isNone),
        )
        t.expect((
          hashQueries->Array.map(
            query => (query->queryField("from_block"), query->queryField("to_block")),
          ),
          await indexer->metricValues("envio_rollback_total"),
          await indexer->metricValues("envio_rollback_target_block"),
        )).toEqual((
          [
            (Some(JSON.Number(9.)), Some(JSON.Number(12.))),
            (Some(JSON.Number(10.)), Some(JSON.Number(12.))),
          ],
          ["1"],
          ["11"],
        ))
      },
    )
  })

  // A hash request the server answers from behind the head fails and is retried,
  // and the failure carries the request it made: counted on the failure and on
  // its response alike, every request would be counted twice.
  Async.it("Counts a block-hash request answered from behind the head once", async t => {
    let hashed = numbers =>
      numbers->Array.map(
        number =>
          JSON.parseOrThrow(
            `{"number":${number->Int.toString},"hash":"${number === 9
                ? parentHash
                : blockHash(number)}"}`,
          ),
      )
    behindRollbackChain->serve(
      ~height=30,
      [
        {
          ...page,
          nextBlock: 21,
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":20,"timestamp":1700000100,"hash":"${blockHash(
                20,
              )}","firstBlockNumber":10,"firstParentHash":"${parentHash}"}`,
          ),
        },
        {
          nextBlock: 31,
          rollbackGuard: JSON.parseOrThrow(
            `{"blockNumber":30,"timestamp":1700000200,"hash":"${blockHash(
                30,
              )}","firstBlockNumber":21,"firstParentHash":"${blockHash(99)}"}`,
          ),
        },
        // The replica that answers first hasn't reached block 9.
        {blocks: [], nextBlock: 9},
        {blocks: hashed([9, 10, 11]), nextBlock: 12},
      ],
    )
    await behindRollbackChain.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        let waited = ref(0)
        while (
          (await indexer->metricValues("envio_rollback_total")) != ["1"] && waited.contents < 500
        ) {
          // Real time: every page comes back over a real socket.
          await Utils.delay(10)
          // The rollback waits out a retry on the clock before it asks again.
          await indexer.advanceTime(100)
          waited := waited.contents + 1
        }
        let hashQueries =
          queries()
          ->Array.filter(
            query =>
              query
              ->queryField("field_selection")
              ->Option.flatMap(JSON.Decode.object)
              ->Option.mapOr(false, selection => selection->Dict.get("log")->Option.isNone),
          )
          ->Array.length
        let hashRequestsCounted =
          (await indexer.metric("envio_source_request_total"))->Array.filterMap(
            ({labels, value}) =>
              labels->Dict.get("method") === Some("getBlockHashes") ? Some(value) : None,
          )
        t.expect((
          hashRequestsCounted,
          await indexer->metricValues("envio_rollback_target_block"),
        )).toEqual(([hashQueries->Int.toString], ["11"]))
      },
    )
  })
})

describe("HyperSync heights", () => {
  Async.it("Reads the height off the server", async t => {
    throughFortyOne->serve(~height=42, [])
    await throughFortyOne->indexToEnd(
      async (indexer, _error) =>
        t.expect(await indexer->metricValues("envio_source_known_height")).toEqual(["42"]),
    )
  })

  let atTheHead = chain(~endBlock=None)
  Async.it("Takes heights pushed over the height stream", async t => {
    atTheHead->serve(~height=11, [{...page, nextBlock: 12}])
    await atTheHead.scenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        let waitForKnownHeight = async height => {
          let waited = ref(0)
          while (
            (await indexer->metricValues("envio_source_known_height")) != [height] &&
              waited.contents < 500
          ) {
            // Real time: heights are pushed over a real socket.
            await Utils.delay(10)
            waited := waited.contents + 1
          }
        }
        await waitForKnownHeight("11")
        let connected = ref(0)
        while (
          (await indexer->metricValues("envio_source_height_stream_connects_total")) != ["1"] &&
            connected.contents < 500
        ) {
          // Real time: the stream connects over a real socket.
          await Utils.delay(10)
          connected := connected.contents + 1
        }
        hyperSync()->MockHyperSyncServer.setHeight(15)
        await waitForKnownHeight("15")
        t.expect(await indexer->metricValues("envio_source_known_height")).toEqual(["15"])
      },
    )
  })
})

describe("HyperSync accounting", () => {
  // Block 12 carries no log, so nothing routes to it. It is still a block the
  // server scanned and returned, which is what the metric counts.
  let throughTwelve = chain(~endBlock=Some(12))
  Async.it("Counts the blocks the server returned, before any routing drops them", async t => {
    throughTwelve->serve([
      {...page, blocks: page.blocks->Option.getOrThrow->Array.concat([blockTwelve])},
    ])
    await throughTwelve->indexToEnd(
      async (indexer, _error) =>
        t.expect(await indexer->metricValues("envio_source_response_blocks_total")).toEqual(["3"]),
    )
  })

  Async.it("Counts zero blocks for a range the server matched nothing in", async t => {
    backfill->serve([])
    await backfill->indexToEnd(
      async (indexer, _error) =>
        t.expect((
          await indexer->metricValues("envio_source_response_blocks_total"),
          await indexer->metricValues("envio_source_response_empty_total"),
        )).toEqual((["0"], ["1"])),
    )
  })

  // A source that is erroring still hammers its endpoint, so a failed page
  // counts its request.
  Async.it("Counts the request a failed page made", async t => {
    backfill->serve([])
    hyperSync()->MockHyperSyncServer.pushRawReply({status: 500, body: "upstream exploded"})
    await backfill->indexToEnd(
      ~whileRunning=async indexer => {
        await indexer->waitForRetry
        // The failed page backs off before the retry that ends the run.
        for _ in 1 to 60 {
          await indexer.advanceTime(1_000)
        }
      },
      async (indexer, error) =>
        t.expect((
          error,
          (await indexer.metric("envio_source_request_total"))->Array.map(
            ({labels, value}) => (labels->Dict.get("method"), value),
          ),
        )).toEqual((None, [(Some("getHeight"), "1"), (Some("getLogs"), "2")])),
    )
  })
})

describe("HyperSync failures worth waiting out", () => {
  Async.it("Waits out a rate limit for as long as the server said", async t => {
    backfill->serve([])
    hyperSync()->MockHyperSyncServer.pushRawReply({
      status: 429,
      headers: dict{"x-ratelimit-reset": "3", "x-ratelimit-remaining": "0"},
      body: "slow down",
    })
    await backfill->indexToEnd(
      ~whileRunning=async indexer => {
        let sent = []
        await Scenario.waitUntil(
          () => {
            sent->Array.pushMany(queries())
            sent->Array.length > 0
          },
          ~message="the rate-limited query",
        )
        await indexer.advanceTime(2_999)
        // Real time: a retry would have to cross a real socket to be seen.
        await Utils.delay(200)
        sent->Array.pushMany(queries())
        let beforeTheReset = sent->Array.length
        await indexer.advanceTime(1)
        t.expect(beforeTheReset).toBe(1)
      },
      async (_indexer, error) => t.expect(error).toBe(None),
    )
  })

  Async.it("Takes a page that made no progress as the server being behind", async t => {
    backfill->serve([{nextBlock: 10}])
    await backfill->indexToEnd(
      ~whileRunning=async indexer => {
        await Scenario.waitUntil(
          () =>
            indexer.allLogsAsJson()->Array.some(
              line =>
                switch line->Dict.get("msg") {
                | Some(String(msg)) => msg->String.includes("hasn't reached block 10")
                | _ => false
                },
            ),
          ~message="the indexer to say the source is behind",
        )
        for _ in 1 to 60 {
          await indexer.advanceTime(1_000)
        }
      },
      async (_indexer, error) => t.expect(error).toBe(None),
    )
  })
})
