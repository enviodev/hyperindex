open Vitest

// The RPC source as a user runs it: a config.yaml naming a local JSON-RPC node,
// a handler selecting fields, and the rows that handler writes. The node is
// scripted per test, so each case controls exactly what the provider answers,
// and its request log shows what the source chose to ask. The port is fixed:
// the config naming it is parsed while vitest collects.
let port = 18660
let url = `http://127.0.0.1:${port->Int.toString}`

let tokenAddress = RpcE2eChain.contractAddress
// A second Token, so a range can be scanned by two partitions.
let otherTokenAddress = "0x3333333333333333333333333333333333333333"
let transferBlock = 100
let txHash = RpcE2eChain.transactionHash(transferBlock)
let blockHash = RpcE2eChain.blockHash(transferBlock)
let parentHash = RpcE2eChain.blockHash(transferBlock - 1)
let mixedCaseAddress = "0xAbC0000000000000000000000000000000000123"

let pingTopic = "0xca6e822df923f741dfe968d15d80a18abd25bd1e748bcb9ad81fea5bbb7386af"
let pongTopic = "0x4d015fcc2a20c24d7be893b3a525eac864b5a53a5f88ef7201a600465c73314e"
let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

let defaultBlock = () =>
  JSON.parseOrThrow(
    `{"number":"0x64","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}","miner":"${mixedCaseAddress}","gasUsed":"0x2a","baseFeePerGas":null}`,
  )
let defaultTransaction = () =>
  JSON.parseOrThrow(
    `{"hash":"${txHash}","gas":"0x5208","gasPrice":"0x7","input":"0xdeadbeef","from":"${mixedCaseAddress}","to":null,"nonce":"0x1","unknownExtraField":"ignored"}`,
  )
let defaultReceipt = () =>
  JSON.parseOrThrow(
    `{"gasUsed":"0x5208","cumulativeGasUsed":"0x5209","effectiveGasPrice":"0x9","status":"0x1","from":"${mixedCaseAddress}","to":null,"l1FeeScalar":"1.5"}`,
  )

// The logs the node holds, by emitter. Every Token log shares one transaction.
let transferFrom = (~address, ~logIndex) => {
  let log = RpcE2eChain.logJson({blockNumber: transferBlock, value: 3, logIndex})
  log->JSON.Decode.object->Option.getOrThrow->Dict.set("address", JSON.String(address))
  log
}

type getLogs =
  | Serve
  // Answers the first `count` eth_getLogs with `error`, the rest as `Serve`.
  | Refuse({count: int, error: string})

let block = ref(defaultBlock())
let transaction = ref(defaultTransaction())
let receipt = ref(defaultReceipt())
let logs = ref([transferFrom(~address=tokenAddress, ~logIndex=0)])
let getLogs = ref(Serve)
let height = ref(transferBlock)
let refused = ref(0)

let answerWith = (
  ~block as blockAnswer=defaultBlock(),
  ~transaction as transactionAnswer=defaultTransaction(),
  ~receipt as receiptAnswer=defaultReceipt(),
  ~logs as logsAnswer=[transferFrom(~address=tokenAddress, ~logIndex=0)],
  ~getLogs as getLogsAnswer=Serve,
  ~height as heightAnswer=transferBlock,
) => {
  block := blockAnswer
  transaction := transactionAnswer
  receipt := receiptAnswer
  logs := logsAnswer
  getLogs := getLogsAnswer
  height := heightAnswer
  refused := 0
}

let lowercased = json => json->JSON.Decode.string->Option.getOrThrow->String.toLowerCase

let servedLogs = (filter: dict<JSON.t>) => {
  let range = key => filter->Dict.getUnsafe(key)->RpcE2eChain.hexParam
  let addresses = switch filter->Dict.get("address") {
  | Some(Array(addresses)) => Some(addresses->Array.map(lowercased))
  | _ => None
  }
  logs.contents->Array.filter(log => {
    let fields = log->JSON.Decode.object->Option.getOrThrow
    let blockNumber = fields->Dict.getUnsafe("blockNumber")->RpcE2eChain.hexParam
    blockNumber >= range("fromBlock") &&
    blockNumber <= range("toBlock") &&
    addresses->Option.mapOr(true, addresses =>
      addresses->Array.includes(fields->Dict.getUnsafe("address")->lowercased)
    )
  })
}

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    let arg = index =>
      request
      ->Dict.getUnsafe("params")
      ->JSON.Decode.array
      ->Option.getOrThrow
      ->Array.getUnsafe(index)
    let result = result => (
      200,
      JSON.stringify(
        JSON.Object(dict{"jsonrpc": String("2.0"), "id": Number(1.), "result": result}),
      ),
    )
    switch (method, getLogs.contents) {
    | ("eth_getLogs", Refuse({count, error})) if refused.contents < count =>
      refused := refused.contents + 1
      (
        200,
        JSON.stringify(
          JSON.Object(
            dict{
              "jsonrpc": String("2.0"),
              "id": Number(1.),
              "error": Object(dict{"code": Number(-32005.), "message": String(error)}),
            },
          ),
        ),
      )
    | ("eth_getLogs", _) =>
      result(JSON.Array(arg(0)->JSON.Decode.object->Option.getOrThrow->servedLogs))
    | ("eth_getBlockByNumber", _) =>
      let number = arg(0)->RpcE2eChain.hexParam
      result(number === transferBlock ? block.contents : RpcE2eChain.blockJson(number))
    | ("eth_getTransactionByHash", _) => result(transaction.contents)
    | ("eth_getTransactionReceipt", _) => result(receipt.contents)
    | ("eth_blockNumber", _) => result(JSON.String(RpcE2eChain.hex(height.contents)))
    | ("eth_chainId", _) => result(JSON.String(RpcE2eChain.hex(1337)))
    | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
    }
  })
)

let schema = `
type Payload {
  id: ID!
  block: String!
  transaction: String!
}
`

// What the handler was given, as text a test can compare: a bigint keeps its
// `n`, and a field present but unset reads `undefined` rather than vanishing.
let handlersSelecting = (~block, ~transaction) => {
  let list = fields => fields->Array.map(field => `"${field}"`)->Array.join(", ")
  `
import { indexer } from "envio";

// Each selected field by name, so one the source left unset reads
// \`undefined\` rather than vanishing from the text.
const show = (value: Record<string, unknown>, fields: string[]) =>
  JSON.stringify(
    Object.fromEntries(fields.map((field) => [field, value[field]])),
    (_key, field) =>
      typeof field === "bigint" ? \`\${field}n\` : field === undefined ? "undefined" : field,
  );

indexer.onEvent(
  {
    contract: "Token",
    event: "Transfer",
    fields: { block: [${block->list}], transaction: [${transaction->list}] },
  },
  async ({ event, context }) => {
    context.Payload.set({
      id: \`\${event.srcAddress}-\${event.logIndex}\`,
      block: show(event.block, [${block->list}]),
      transaction: show(event.transaction, [${transaction->list}]),
    });
  },
);
`
}

let chainYaml = (~startBlock=transferBlock, ~endBlock=transferBlock, ~rpcUrl=url, ~addresses) =>
  `
chains:
  - id: 1337
    start_block: ${startBlock->Int.toString}
    end_block: ${endBlock->Int.toString}
    rpc:
      url: ${rpcUrl}
      for: sync
    contracts:
      - name: Token
        address:
${addresses->Array.map(address => `          - "${address}"`)->Array.join("\n")}
`

let tokenEvents = `
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
`

let selecting = (
  ~block=[],
  ~transaction=[],
  ~addressFormat="lowercase",
  ~addresses=[tokenAddress],
) =>
  Scenario.make(
    ~schema,
    ~handlers=handlersSelecting(~block, ~transaction),
    ~configYaml=`
name: rpc-source
rollback_on_reorg: false
address_format: ${addressFormat}
${tokenEvents}${chainYaml(~addresses)}`,
  )

// The requests made since `since`, as how many times each method was called.
let callCounts = (~since, methods) => {
  let requests = mock().requests->Array.slice(~start=since)
  methods->Array.map(method =>
    requests->Array.filter(body => body->String.includes(`"method":"${method}"`))->Array.length
  )
}

// What the indexer said each time a page failed and was put back to retry.
let failureMessages = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filterMap(line =>
    switch (line->Dict.get("backOffMilliseconds"), line->Dict.get("msg")) {
    | (Some(_), Some(String(message))) => Some(message)
    | _ => None
    }
  )

type row = {id: string, block: string, transaction: string}
type outcome = {
  // What each handler call was given, keyed by emitter and log index.
  payloads: array<(string, JSON.t, JSON.t)>,
  // How the run ended when it failed: the message it stopped with.
  error: option<string>,
  // The node's requests during the run.
  since: int,
}

let readPayloads = async (indexer: IndexerRunner.t) => {
  let rows: array<row> = await indexer.query("Payload")
  rows
  ->Array.toSorted((a, b) => String.compare(a.id, b.id))
  ->Array.map(({id, block, transaction}) => (
    id,
    block->JSON.parseOrThrow,
    transaction->JSON.parseOrThrow,
  ))
}

// Indexes the transfer block and hands back what came of it: the run either
// reaches its end block or stops on an error.
let indexTransferBlock = async (scenario, ~maxAddrInPartition=?, ~whileRunning=?, ~atEnd=?) => {
  let since = mock().requests->Array.length
  let exited = ref(false)
  let error = ref(None)
  let payloads = ref([])
  await scenario->Scenario.run(
    ~yamlSources=true,
    ~maxAddrInPartition?,
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
      payloads := (await indexer->readPayloads)
      switch atEnd {
      | Some(step) => await step(indexer)
      | None => ()
      }
    },
  )
  {payloads: payloads.contents, error: error.contents->Option.flatMap(message => message), since}
}

let onlyPayload = ({payloads}) =>
  switch payloads {
  | [(_, block, transaction)] => (block, transaction)
  | _ =>
    JsError.throwWithMessage(`Expected one payload, got ${payloads->Array.length->Int.toString}`)
  }
let onlyTransaction = outcome => outcome->onlyPayload->Pair.second
let onlyBlock = outcome => outcome->onlyPayload->Pair.first

let transactionReads = ["eth_getTransactionByHash", "eth_getTransactionReceipt"]

let parse = JSON.parseOrThrow

describe("RPC field selection", () => {
  let transactionOnly = selecting(~transaction=["gas", "input", "nonce"])
  Async.it("Reads a transaction-only selection from the transaction alone", async t => {
    answerWith()
    let outcome = await transactionOnly->indexTransferBlock
    t.expect((
      outcome->onlyTransaction,
      callCounts(~since=outcome.since, transactionReads),
    )).toEqual((parse(`{"gas":"21000n","input":"0xdeadbeef","nonce":"1n"}`), [1, 0]))
  })

  let receiptOnly = selecting(~transaction=["gasUsed", "cumulativeGasUsed", "status"])
  Async.it("Reads a receipt-only selection from the receipt alone", async t => {
    answerWith()
    let outcome = await receiptOnly->indexTransferBlock
    t.expect((
      outcome->onlyTransaction,
      callCounts(~since=outcome.since, transactionReads),
    )).toEqual((parse(`{"gasUsed":"21000n","cumulativeGasUsed":"21001n","status":1}`), [0, 1]))
  })

  let fromAndTo = selecting(~transaction=["from", "to"])
  Async.it("Serves a selection carried by both responses from the transaction", async t => {
    answerWith()
    let outcome = await fromAndTo->indexTransferBlock
    // `to` is null on this transaction: a contract creation, not a gap.
    t.expect((
      outcome->onlyTransaction,
      callCounts(~since=outcome.since, transactionReads),
    )).toEqual((
      parse(`{"from":"0xabc0000000000000000000000000000000000123","to":"undefined"}`),
      [1, 0],
    ))
  })

  // `from`/`to`/`type` ride on both responses, so a selection that also needs a
  // receipt-only field must read them off the receipt rather than pay for a
  // second request. Nothing marks them missing, so a regression here would show
  // up as `undefined` in a handler instead of an error.
  let alsoNeedingTheReceipt = selecting(~transaction=["from", "to", "type", "gasUsed"])
  Async.it("Serves a selection carried by both responses from the receipt", async t => {
    answerWith(
      ~receipt=parse(`{"gasUsed":"0x5208","from":"0x1111111111111111111111111111111111111111","to":"0x2222222222222222222222222222222222222222","type":"0x2"}`),
    )
    let outcome = await alsoNeedingTheReceipt->indexTransferBlock
    t.expect((
      outcome->onlyTransaction,
      callCounts(~since=outcome.since, transactionReads),
    )).toEqual((
      parse(`{"from":"0x1111111111111111111111111111111111111111","to":"0x2222222222222222222222222222222222222222","type":2,"gasUsed":"21000n"}`),
      [0, 1],
    ))
  })

  let offTheLog = selecting(~transaction=["hash", "transactionIndex"])
  Async.it("Takes hash and transactionIndex off the log without a request", async t => {
    answerWith()
    let outcome = await offTheLog->indexTransferBlock
    t.expect((
      outcome->onlyTransaction,
      callCounts(~since=outcome.since, transactionReads),
    )).toEqual((parse(`{"hash":"${txHash}","transactionIndex":0}`), [0, 0]))
  })

  let effectiveGasPrice = selecting(~transaction=["effectiveGasPrice"])
  Async.it("Falls back to the transaction's gasPrice when the receipt omits it", async t => {
    answerWith(~receipt=parse(`{"gasUsed":"0x5208","status":"0x1"}`))
    let outcome = await effectiveGasPrice->indexTransferBlock
    t.expect(outcome->onlyTransaction).toEqual(parse(`{"effectiveGasPrice":"7n"}`))
  })

  Async.it("Stops on a receipt with neither effectiveGasPrice nor gasPrice", async t => {
    answerWith(~transaction=parse(`{"hash":"${txHash}"}`), ~receipt=parse(`{"gasUsed":"0x5208"}`))
    let outcome = await effectiveGasPrice->indexTransferBlock
    t.expect((
      outcome.payloads,
      outcome.error->Option.map(message => message->String.includes("effectiveGasPrice")),
    )).toEqual(([], Some(true)))
  })

  let gas = selecting(~transaction=["gas"])
  Async.it("Stops rather than index an event missing a selected field", async t => {
    answerWith(~transaction=parse(`{"hash":"${txHash}"}`))
    let outcome = await gas->indexTransferBlock
    t.expect((outcome.payloads, outcome.error)).toEqual((
      [],
      Some(
        "The indexer doesn't have data-sources which can continue fetching. The last one was disabled because the RPC response is missing the selected transaction field: gas. Please double-check your RPC provider returns correct data.",
      ),
    ))
  })

  let blockGasUsed = selecting(~block=["gasUsed"])
  Async.it("Stops when a selected block field is missing", async t => {
    answerWith(
      ~block=parse(
        `{"number":"0x64","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}"}`,
      ),
    )
    let outcome = await blockGasUsed->indexTransferBlock
    t.expect(outcome.error->Option.map(message => message->String.includes("gasUsed"))).toEqual(
      Some(true),
    )
  })

  let blockFields = selecting(~block=["number", "timestamp", "hash", "gasUsed", "baseFeePerGas"])
  Async.it("Reads selected block fields, keeping a nullable one absent", async t => {
    answerWith()
    let outcome = await blockFields->indexTransferBlock
    t.expect(outcome->onlyBlock).toEqual(
      parse(
        `{"number":100,"timestamp":100000000,"hash":"${blockHash}","gasUsed":"42n","baseFeePerGas":"undefined"}`,
      ),
    )
  })

  let minerLowercase = selecting(~block=["miner"])
  let minerChecksum = selecting(~block=["miner"], ~addressFormat="checksum")
  Async.it("Normalizes block addresses to the configured address format", async t => {
    answerWith()
    let lowercase = await minerLowercase->indexTransferBlock
    answerWith()
    let checksum = await minerChecksum->indexTransferBlock
    t.expect((lowercase->onlyBlock, checksum->onlyBlock)).toEqual((
      parse(`{"miner":"0xabc0000000000000000000000000000000000123"}`),
      parse(`{"miner":"0xABc0000000000000000000000000000000000123"}`),
    ))
  })

  let transactionAddresses = ["from", "contractAddress", "gasUsed"]
  let transactionAddressesLowercase = selecting(~transaction=transactionAddresses)
  let transactionAddressesChecksum = selecting(
    ~transaction=transactionAddresses,
    ~addressFormat="checksum",
  )
  Async.it("Normalizes transaction addresses to the configured address format", async t => {
    let receipt = parse(
      `{"gasUsed":"0x5208","from":"${mixedCaseAddress}","contractAddress":"0xdEf0000000000000000000000000000000000456"}`,
    )
    answerWith(~receipt)
    let lowercase = await transactionAddressesLowercase->indexTransferBlock
    answerWith(~receipt)
    let checksum = await transactionAddressesChecksum->indexTransferBlock
    t.expect((lowercase->onlyTransaction, checksum->onlyTransaction)).toEqual((
      parse(`{"from":"0xabc0000000000000000000000000000000000123","contractAddress":"0xdef0000000000000000000000000000000000456","gasUsed":"21000n"}`),
      parse(`{"from":"0xABc0000000000000000000000000000000000123","contractAddress":"0xDEf0000000000000000000000000000000000456","gasUsed":"21000n"}`),
    ))
  })

  let lists = selecting(~transaction=["accessList", "authorizationList"])
  Async.it("Materialises accessList and authorizationList onto the payload", async t => {
    let listAddress = "0x" ++ "22"->String.repeat(20)
    let storageKey = "0x" ++ "11"->String.repeat(32)
    answerWith(
      ~transaction=parse(
        `{"hash":"${txHash}","accessList":[{"address":"${listAddress}","storageKeys":["${storageKey}"]}],"authorizationList":[{"chainId":"0x1","address":"${listAddress}","nonce":"0x1","yParity":"0x0","r":"0x1","s":"0x1"}]}`,
      ),
    )
    let outcome = await lists->indexTransferBlock
    t.expect(outcome->onlyTransaction).toEqual(
      parse(
        `{"accessList":[{"address":"${listAddress}","storageKeys":["${storageKey}"]}],"authorizationList":[{"chainId":"1n","address":"${listAddress}","nonce":1,"yParity":0,"r":"0x1","s":"0x1"}]}`,
      ),
    )
  })

  // A pre-EIP-2930 transaction has no `accessList` at all. Treating that as a
  // missing selected field would stop the indexer.
  let accessList = selecting(~transaction=["accessList"])
  Async.it("Accepts a legacy transaction that carries no accessList", async t => {
    answerWith(~transaction=parse(`{"hash":"${txHash}","gas":"0x5208"}`))
    let outcome = await accessList->indexTransferBlock
    t.expect(outcome->onlyTransaction).toEqual(parse(`{"accessList":"undefined"}`))
  })

  let l1FeeScalar = selecting(~transaction=["l1FeeScalar"])
  Async.it("Reads a decimal-encoded l1FeeScalar", async t => {
    answerWith()
    let outcome = await l1FeeScalar->indexTransferBlock
    t.expect(outcome->onlyTransaction).toEqual(parse(`{"l1FeeScalar":1.5}`))
  })

  // The reason the source keeps the chain's blocks and transactions at all:
  // partitions are address slices, not range slices, so several of them scan
  // the same blocks.
  let twoPartitions = (~transaction) =>
    selecting(~block=["gasUsed"], ~transaction, ~addresses=[tokenAddress, otherTokenAddress])
  let gasOverTwoPartitions = twoPartitions(~transaction=["gas"])
  Async.it("Reads a transaction once for partitions that share its block", async t => {
    answerWith(
      ~logs=[
        transferFrom(~address=tokenAddress, ~logIndex=0),
        transferFrom(~address=otherTokenAddress, ~logIndex=1),
      ],
    )
    let outcome = await gasOverTwoPartitions->indexTransferBlock(~maxAddrInPartition=1)
    t.expect((
      outcome.payloads->Array.map(((_, _, transaction)) => transaction),
      callCounts(~since=outcome.since, ["eth_getLogs", "eth_getTransactionByHash"]),
    )).toEqual(([parse(`{"gas":"21000n"}`), parse(`{"gas":"21000n"}`)], [2, 1]))
  })

  // `to` is null on a contract creation. Judged by stored values alone the
  // transaction would look unfetched, and be asked for again.
  let toOverTwoPartitions = twoPartitions(~transaction=["to"])
  Async.it("Does not read a transaction again for a field that came back null", async t => {
    answerWith(
      ~logs=[
        transferFrom(~address=tokenAddress, ~logIndex=0),
        transferFrom(~address=otherTokenAddress, ~logIndex=1),
      ],
    )
    let outcome = await toOverTwoPartitions->indexTransferBlock(~maxAddrInPartition=1)
    t.expect((
      outcome.payloads->Array.map(((_, _, transaction)) => transaction),
      callCounts(~since=outcome.since, ["eth_getTransactionByHash"]),
    )).toEqual(([parse(`{"to":"undefined"}`), parse(`{"to":"undefined"}`)], [1]))
  })
})

// A garbled value and a response for the wrong block are both one node
// answering badly, not a selection the chain cannot serve. Disabling the source
// over one would stop an indexer with a single RPC for good, so they have to be
// retried — and a retry that then gets a good answer indexes the event.
describe("RPC answers worth retrying", () => {
  // Fails the first attempt with `bad`, waits for the indexer to say so, then
  // answers well and lets the backoff run out.
  let recoverFrom = async (scenario, ~good) => {
    let firstFailure = ref(None)
    let outcome = await scenario->indexTransferBlock(~whileRunning=async indexer => {
      await Scenario.waitUntil(
        () => indexer->failureMessages->Array.length > 0,
        ~message="the page to fail",
      )
      firstFailure := indexer->failureMessages->Array.get(0)
      good()
      // The query backoff, walked in steps so the retry lands whatever it is.
      let advanced = ref(0)
      while (await indexer->readPayloads)->Array.length === 0 && advanced.contents < 120_000 {
        await indexer.advanceTime(1_000)
        advanced := advanced.contents + 1_000
      }
    })
    (firstFailure.contents, outcome)
  }

  let gas = selecting(~transaction=["gas"])
  Async.it("Retries a value it cannot decode rather than stopping", async t => {
    answerWith(~transaction=parse(`{"hash":"${txHash}","gas":"not-hex"}`))
    let (failure, outcome) = await gas->recoverFrom(~good=() => transaction := defaultTransaction())
    t.expect((
      failure->Option.map(message => message->String.includes("gas")),
      outcome.error,
      outcome->onlyTransaction,
    )).toEqual((Some(true), None, parse(`{"gas":"21000n"}`)))
  })

  // Every fetched block is read for its reorg fields whether or not they are
  // selected, so a response missing one says nothing about whether the
  // selection is servable: every EVM chain has a block hash.
  let blockGasUsed = selecting(~block=["gasUsed"])
  Async.it("Retries a block missing a field only the reorg check needs", async t => {
    answerWith(
      ~block=parse(
        `{"number":"0x64","timestamp":"0x5f5e100","parentHash":"${parentHash}","gasUsed":"0x2a"}`,
      ),
    )
    let (failure, outcome) = await blockGasUsed->recoverFrom(~good=() => block := defaultBlock())
    t.expect((
      failure->Option.map(message => message->String.includes("hash")),
      outcome.error,
      outcome->onlyBlock,
    )).toEqual((Some(true), None, parse(`{"gasUsed":"42n"}`)))
  })

  // A load-balanced provider can answer eth_getBlockByNumber from a node that
  // has drifted, returning the neighbouring block.
  let timestamp = selecting(~block=["timestamp"])
  Async.it("Retries a response for the wrong block", async t => {
    answerWith(
      ~block=parse(
        `{"number":"0x65","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}"}`,
      ),
    )
    let (failure, outcome) = await timestamp->recoverFrom(~good=() => block := defaultBlock())
    t.expect((
      failure->Option.map(
        message => message->String.includes("block 100") && message->String.includes("block 101"),
      ),
      outcome.error,
      outcome->onlyBlock,
    )).toEqual((Some(true), None, parse(`{"timestamp":100000000}`)))
  })

  // A page that ends in a retry still made its requests, and they are counted.
  Async.it("Counts the requests a failed page made", async t => {
    answerWith(~transaction=parse(`{"hash":"${txHash}","gas":"not-hex"}`))
    let methods = ref([])
    let _ = await gas->indexTransferBlock(
      ~whileRunning=async indexer => {
        await Scenario.waitUntil(
          () => indexer->failureMessages->Array.length > 0,
          ~message="the page to fail",
        )
        methods :=
          (await indexer.metric("envio_source_request_total"))
          ->Array.filterMap(({labels}) => labels->Dict.get("method"))
          ->Array.toSorted(String.compare)
        transaction := defaultTransaction()
        let advanced = ref(0)
        while (await indexer->readPayloads)->Array.length === 0 && advanced.contents < 120_000 {
          await indexer.advanceTime(1_000)
          advanced := advanced.contents + 1_000
        }
      },
    )
    t.expect(
      ["eth_getBlockByNumber", "eth_getLogs", "eth_getTransactionByHash"]->Array.every(
        method => methods.contents->Array.includes(method),
      ),
    ).toBe(true)
  })
})

// The eth_getLogs ranges asked for since `since`, as numbers.
let logRangesSince = (~since) =>
  mock().requests
  ->Array.slice(~start=since)
  ->Array.filterMap(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    switch request->Dict.getUnsafe("method")->JSON.Decode.string {
    | Some("eth_getLogs") =>
      let filter =
        request
        ->Dict.getUnsafe("params")
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      Some((
        filter->Dict.getUnsafe("fromBlock")->RpcE2eChain.hexParam,
        filter->Dict.getUnsafe("toBlock")->RpcE2eChain.hexParam,
      ))
    | _ => None
    }
  })

// A long range, so the source pages it by its own block interval.
let longRange = Scenario.make(
  ~schema,
  ~handlers=handlersSelecting(~block=[], ~transaction=[]),
  ~configYaml=`
name: rpc-source-paging
rollback_on_reorg: false
${tokenEvents}${chainYaml(~startBlock=0, ~endBlock=1_000_000, ~addresses=[tokenAddress])}`,
)

let pagesAsked = async (~count) => {
  let since = mock().requests->Array.length
  let ranges = ref([])
  await longRange->Scenario.run(~yamlSources=true, async (~indexer as _, ~source as _) => {
    await Scenario.waitUntil(
      () => logRangesSince(~since)->Array.length >= count,
      ~message=`${count->Int.toString} eth_getLogs requests`,
    )
    ranges := logRangesSince(~since)->Array.slice(~start=0, ~end=count)
  })
  ranges.contents
}

describe("RPC block ranges", () => {
  Async.it("Shrinks the range a provider found too dense, then grows it back", async t => {
    answerWith(
      ~logs=[],
      ~height=1_000_000,
      ~getLogs=Refuse({count: 1, error: "More than 50000 logs returned"}),
    )
    // Starts at 10000 blocks, takes a fifth off for the refusal, then grows by
    // 500 a page.
    t.expect(await pagesAsked(~count=3)).toEqual([(0, 9999), (0, 7999), (8000, 16499)])
  })

  Async.it("Narrows to the range a provider's message suggested", async t => {
    answerWith(
      ~logs=[],
      ~height=1_000_000,
      ~getLogs=Refuse({
        count: 1,
        error: "query exceeds max results 20000, retry with the range 6000000-6000509",
      }),
    )
    t.expect(await pagesAsked(~count=2)).toEqual([(0, 9999), (0, 509)])
  })
})

// The filters a partition's eth_getLogs carry, as `address;topics`, sorted.
let logFiltersSince = (~since) =>
  mock().requests
  ->Array.slice(~start=since)
  ->Array.filterMap(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    switch (
      request->Dict.getUnsafe("method")->JSON.Decode.string,
      request->Dict.getUnsafe("params"),
    ) {
    | (Some("eth_getLogs"), Array([Object(filter)])) =>
      let address = filter->Dict.get("address")->Option.getOr(JSON.Null)->JSON.stringify
      let topics = filter->Dict.get("topics")->Option.getOr(JSON.Array([]))->JSON.stringify
      Some(`address=${address};topics=${topics}`)
    | _ => None
    }
  })
  ->Array.toSorted(String.compare)

let mixedRegistrations = Scenario.make(
  ~schema,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "PingSource", event: "Ping", wildcard: true }, async () => {});
indexer.onEvent({ contract: "PongSource", event: "Pong", wildcard: true }, async () => {});
// Any contract's approvals, as long as the owner is one of the Tokens.
indexer.onEvent(
  {
    contract: "Token",
    event: "Approval",
    wildcard: true,
    where: ({ chain }) => ({ params: { owner: chain.Token.addresses } }),
  },
  async () => {},
);
`,
  ~configYaml=`
name: rpc-source-filters
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
  - name: PingSource
    events:
      - event: Ping()
  - name: PongSource
    events:
      - event: Pong()
${chainYaml(~addresses=[tokenAddress])}`,
)

describe("RPC log filters", () => {
  Async.it("Asks for each kind of registration with the filter it needs", async t => {
    answerWith(~logs=[])
    let outcome = await mixedRegistrations->indexTransferBlock
    let address = tokenAddress->String.toLowerCase
    let addressTopic = "0x000000000000000000000000" ++ address->String.slice(~start=2)
    t.expect((outcome.error, logFiltersSince(~since=outcome.since))).toEqual((
      None,
      [
        `address=["${address}"];topics=[["${RpcE2eChain.transferSighash}"]]`,
        `address=null;topics=[["${approvalTopic}"],["${addressTopic}"]]`,
        `address=null;topics=[["${pingTopic}","${pongTopic}"]]`,
      ]->Array.toSorted(String.compare),
    ))
  })
})

// A provider's api key rides in its url, and the source's name is printed in
// every log line and metric label, so the name keeps only the host.
let keyedUrl = Scenario.make(
  ~schema,
  ~handlers=handlersSelecting(~block=[], ~transaction=[]),
  ~configYaml=`
name: rpc-source-name
rollback_on_reorg: false
${tokenEvents}${chainYaml(~rpcUrl=`${url}/?api_key=123`, ~addresses=[tokenAddress])}`,
)

describe("RPC source name", () => {
  Async.it("Names the source by its host, leaving the api key out", async t => {
    answerWith()
    let sources = ref([])
    let _ = await keyedUrl->indexTransferBlock(
      ~atEnd=async indexer => {
        sources :=
          (await indexer.metric("envio_source_known_height"))->Array.filterMap(
            ({labels}) => labels->Dict.get("source"),
          )
      },
    )
    t.expect(sources.contents).toEqual(["RPC (127.0.0.1:18660)"])
  })
})

describe("RPC source against a live provider", () => {
  let token =
    Env.envioApiToken->Option.getOrThrow(
      ~message="ENVIO_API_TOKEN env var must be set to run the live RPC height test",
    )
  let live = Scenario.make(
    ~schema,
    ~handlers=handlersSelecting(~block=[], ~transaction=[]),
    ~configYaml=`
name: rpc-source-live
rollback_on_reorg: false
${tokenEvents}
chains:
  - id: 1
    start_block: 21994218
    end_block: 21994218
    rpc:
      url: https://eth.rpc.hypersync.xyz/${token}
      for: sync
    contracts:
      - name: Token
        address: "${tokenAddress}"
`,
  )
  Async.itWithOptions("Reads the chain's height off the provider", {retry: 3}, async t => {
    let known = ref([])
    let exited = ref(false)
    await live->Scenario.run(
      ~yamlSources=true,
      ~onExit=() => exited := true,
      async (~indexer, ~source as _) => {
        // The height, and the one block, come from a provider over the network.
        await Scenario.waitUntil(
          () => exited.contents,
          ~message="the live block to be indexed",
          ~timeoutMs=20_000.,
        )
        known :=
          (await indexer.metric("envio_source_known_height"))->Array.filterMap(
            ({value}) => value->Int.fromString,
          )
      },
    )
    t.expect(known.contents->Array.map(height => height > 21994218 && height < 30000000)).toEqual([
      true,
    ])
  })
})
