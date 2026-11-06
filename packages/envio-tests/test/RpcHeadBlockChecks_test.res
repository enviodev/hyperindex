open Vitest

// Near the head, a load-balanced RPC provider can answer eth_getLogs from a
// node that doesn't have the newest blocks yet, or from one still on a branch
// the chain left, while the headers come from a node that is up to date. The
// answer says nothing about it. So at the head every block of a range is read
// by its header and checked against it before any of its logs are trusted: the
// logs must carry the header's hash, and a block with none of our logs whose
// logsBloom says it may hold some is asked again by its hash.
let rpcPort = 18741

let token = "0x1000000000000000000000000000000000000001"
let otherToken = "0x2000000000000000000000000000000000000002"
let holder = "0x3000000000000000000000000000000000000003"

let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

let event = (
  ~blockNumber,
  ~logIndex=0,
  ~address=token,
  ~topic=transferTopic,
  ~value=blockNumber,
): ServedEvmChain.log => {
  blockNumber,
  logIndex,
  address,
  topics: [topic, holder->ServedEvmChain.addressTopic, holder->ServedEvmChain.addressTopic],
  data: value->ServedEvmChain.hex->ServedEvmChain.dropPrefix->ServedEvmChain.word,
}

let backfillHeight = 20

// How the provider answers eth_getLogs for a while: correctly, or the way a
// node that is behind or on another branch does.
type fault =
  | Honest
  // Requests touching `block` are answered by a node whose newest block is
  // `block - 1`: a range loses the block's logs, and asking for the block by
  // hash is an error. Lasts for `answers` such requests.
  | LaggingReplica({block: int, mutable answers: int})
  // The next range touching `block` leaves its logs out.
  | RangeHole({block: int, mutable answers: int})
  // The next range touching `block` answers it from a branch the chain left:
  // under another hash, with another value.
  | ReplacedBranch({block: int, mutable answers: int})
  // Refuses every eth_getLogs by blockHash, the way publicnode's Polygon
  // endpoint does, while reads by number work.
  | NoBlockHashReads
  // A lagging replica that refuses a hash it doesn't know with the same
  // "archive" error, the way publicnode's Base and BSC endpoints do, while it
  // answers the hashes it has.
  | LaggingReplicaRefusingAsArchive({block: int, mutable answers: int})
  // Throttles the next reads of `block` by hash with a JSON-RPC error.
  | RateLimitedBlockHashReads({block: int, mutable answers: int})

type chain = {mutable height: int, mutable logs: array<ServedEvmChain.log>, mutable fault: fault}
let chain = {height: backfillHeight, logs: [], fault: Honest}

// Every eth_getLogs and eth_getBlockByNumber the provider was asked, as
// `getLogs from-to`, `getLogs block N` for a read by hash, or `header N`.
let calls: array<string> = []

let envelope = (request, field, value) =>
  JSON.stringify(
    JSON.Object(
      Dict.fromArray([
        ("jsonrpc", JSON.String("2.0")),
        ("id", request->Dict.getUnsafe("id")),
        (field, value),
      ]),
    ),
  )

let replacedBranchHash = blockNumber =>
  ("b" ++ blockNumber->Int.toString(~radix=16))->ServedEvmChain.word

let rpcLog = (log: ServedEvmChain.log, ~blockHash=?) => {
  let json = log->ServedEvmChain.rpcLog
  switch (json, blockHash) {
  | (JSON.Object(fields), Some(blockHash)) => fields->Dict.set("blockHash", JSON.String(blockHash))
  | _ => ()
  }
  json
}

// The filter's blocks: the range, or the one block a hash names.
let filterBlocks = filter =>
  switch filter->Dict.get("blockHash") {
  | Some(hash) =>
    let block = hash->ServedEvmChain.quantity
    (block, block)
  | None => (
      filter->Dict.getUnsafe("fromBlock")->ServedEvmChain.quantity,
      filter->Dict.getUnsafe("toBlock")->ServedEvmChain.quantity,
    )
  }

let getLogs = (request, filter, ~fault, ~calls) => {
  let (fromBlock, toBlock) = filter->filterBlocks
  calls
  ->Array.push(
    switch filter->Dict.get("blockHash") {
    | Some(_) => `getLogs block ${fromBlock->Int.toString}`
    | None => `getLogs ${fromBlock->Int.toString}-${toBlock->Int.toString}`
    },
  )
  ->ignore
  let matched = chain.logs->Array.filter(log => ServedEvmChain.rpcFilterMatches(filter, log))
  let honest = () => envelope(request, "result", JSON.Array(matched->Array.map(log => rpcLog(log))))
  let touches = block => fromBlock <= block && block <= toBlock
  let archiveRefusal = () =>
    envelope(
      request,
      "error",
      JSON.Object(
        dict{
          "code": JSON.Number(-32602.),
          "message": JSON.String("Archive requests require a personal token."),
        },
      ),
    )
  switch fault {
  | NoBlockHashReads if filter->Dict.has("blockHash") => archiveRefusal()
  | RateLimitedBlockHashReads(limit)
    if limit.answers > 0 && filter->Dict.has("blockHash") && touches(limit.block) =>
    limit.answers = limit.answers - 1
    envelope(
      request,
      "error",
      JSON.Object(
        dict{"code": JSON.Number(-32005.), "message": JSON.String("rate limit exceeded")},
      ),
    )
  | LaggingReplicaRefusingAsArchive(lag) if lag.answers > 0 && touches(lag.block) =>
    lag.answers = lag.answers - 1
    if filter->Dict.has("blockHash") {
      archiveRefusal()
    } else {
      envelope(
        request,
        "result",
        JSON.Array(
          matched->Array.filter(log => log.blockNumber < lag.block)->Array.map(log => rpcLog(log)),
        ),
      )
    }
  | LaggingReplica(lag) if lag.answers > 0 && touches(lag.block) =>
    lag.answers = lag.answers - 1
    if filter->Dict.has("blockHash") {
      envelope(
        request,
        "error",
        JSON.Object(dict{"code": JSON.Number(-32000.), "message": JSON.String("unknown block")}),
      )
    } else {
      envelope(
        request,
        "result",
        JSON.Array(
          matched->Array.filter(log => log.blockNumber < lag.block)->Array.map(log => rpcLog(log)),
        ),
      )
    }
  | RangeHole(hole) if hole.answers > 0 && touches(hole.block) && fromBlock < toBlock =>
    hole.answers = hole.answers - 1
    envelope(
      request,
      "result",
      JSON.Array(
        matched->Array.filter(log => log.blockNumber != hole.block)->Array.map(log => rpcLog(log)),
      ),
    )
  | ReplacedBranch(branch) if branch.answers > 0 && touches(branch.block) =>
    branch.answers = branch.answers - 1
    envelope(
      request,
      "result",
      JSON.Array(
        matched->Array.map(log =>
          log.blockNumber == branch.block
            ? rpcLog(
                {
                  ...log,
                  data: 1->ServedEvmChain.hex->ServedEvmChain.dropPrefix->ServedEvmChain.word,
                },
                ~blockHash=branch.block->replacedBranchHash,
              )
            : rpcLog(log)
        ),
      ),
    )
  | _ => honest()
  }
}

// The same chain behind a second provider, which always answers honestly.
let fallbackRpcPort = 18742
let fallbackCalls: array<string> = []

let serve = (~port, ~fault, ~calls) =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let params = request->Dict.getUnsafe("params")->JSON.Decode.array->Option.getOrThrow
    switch request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow {
    | "eth_getLogs" => (
        200,
        getLogs(
          request,
          params->Array.getUnsafe(0)->JSON.Decode.object->Option.getOrThrow,
          ~fault=fault(),
          ~calls,
        ),
      )
    | "eth_getBlockByNumber" =>
      let blockNumber = params->Array.getUnsafe(0)->ServedEvmChain.quantity
      calls->Array.push(`header ${blockNumber->Int.toString}`)->ignore
      (200, envelope(request, "result", blockNumber->ServedEvmChain.rpcBlock(~logs=chain.logs)))
    | "eth_blockNumber" => (
        200,
        envelope(request, "result", JSON.String(chain.height->ServedEvmChain.hex)),
      )
    | method => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
    }
  })

let getServer = RpcE2eChain.serveDuringSuite(() =>
  serve(~port=rpcPort, ~fault=() => chain.fault, ~calls)
)
let getFallbackServer = RpcE2eChain.serveDuringSuite(() =>
  serve(~port=fallbackRpcPort, ~fault=() => Honest, ~calls=fallbackCalls)
)

let makeScenario = (~name, ~rpc, ~maxReorgDepth=5) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1337
    rpc:${rpc}
    start_block: 1
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    contracts:
      - name: Token
        address: "${token}"
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});
`,
    // A real RPC source against a local server: its requests resolve on real I/O.
    ~virtualTime=false,
  )

let scenario = makeScenario(
  ~name="rpc-head-block-checks",
  ~rpc=`
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      polling_interval: 10`,
)

// Arbitrum and Optimism default to this: they don't reorg, but their providers
// lag all the same.
let noReorgScenario = makeScenario(
  ~name="rpc-head-block-checks-no-reorg",
  ~maxReorgDepth=0,
  ~rpc=`
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      polling_interval: 10`,
)

let failoverScenario = makeScenario(
  ~name="rpc-head-block-checks-failover",
  ~rpc=`
      - url: ${ServedEvmChain.url(rpcPort)}
        for: sync
        polling_interval: 10
      - url: ${ServedEvmChain.url(fallbackRpcPort)}
        for: fallback
        polling_interval: 10`,
)

type seen = {id: string}

let seenIds = async (indexer: IndexerRunner.t) => {
  let rows: array<seen> = await indexer.query("Seen")
  rows->Array.map(row => row.id)->Array.toSorted(String.compare)
}

let waitForSeen = async (indexer, id, ~timeoutMs=10_000.) => {
  let deadline = Date.now() +. timeoutMs
  while !((await indexer->seenIds)->Array.includes(id)) {
    if Date.now() > deadline {
      JsError.throwWithMessage(
        `Timed out waiting for ${id} to be indexed. Indexed: ${(await indexer->seenIds)->Array.join(
            ", ",
          )}`,
      )
    }
    await Utils.delay(10)
  }
}

// The progress block's timestamp once progress has reached `atLeast`: the
// metric moves with the batch write, a moment after the batch's events land.
let progressBlockTime = async (indexer: IndexerRunner.t, ~atLeast) => {
  let read = async name =>
    (await indexer.metric(name))->Array.map(metric => metric.value)->Array.join(",")
  let deadline = Date.now() +. 5_000.
  while (
    (await read("envio_progress_block"))->Int.fromString->Option.getOr(0) < atLeast &&
      Date.now() < deadline
  ) {
    await Utils.delay(10)
  }
  await read("envio_progress_block_time_seconds")
}

let takeCalls = () => {
  let taken = calls->Array.toSorted(String.compare)
  calls->Utils.Array.clearInPlace
  taken
}

// Indexes up to the backfill height with the provider answering the way
// `startupFault` says, then lets the chain grow to `height` with `logs` and the
// provider answering the way `fault` says, and runs `body` once the event
// `waitFor` names is indexed.
let runAtHead = async (
  ~scenario=scenario,
  ~backfillHeight=backfillHeight,
  ~startupFault=Honest,
  ~logs,
  ~height,
  ~fault,
  ~waitFor,
  ~waitForTimeoutMs=?,
  body,
) => {
  let _ = getServer()
  let _ = getFallbackServer()
  chain.height = backfillHeight
  chain.logs = [event(~blockNumber=3), ...logs]
  chain.fault = startupFault
  calls->Utils.Array.clearInPlace
  fallbackCalls->Utils.Array.clearInPlace
  await scenario->Scenario.run(~yamlSources=true, async (~indexer, ~source as _) => {
    await indexer->waitForSeen("3-0-3")
    await indexer.waitUntilReady()
    let backfill = takeCalls()
    fallbackCalls->Utils.Array.clearInPlace
    chain.fault = fault
    chain.height = height
    await indexer->waitForSeen(waitFor, ~timeoutMs=?waitForTimeoutMs)
    await body(~indexer, ~backfill, ~head=takeCalls())
  })
}

let blockOf = call =>
  call
  ->String.split(" ")
  ->Array.getUnsafe(1)
  ->String.split("-")
  ->Array.map(n => n->Int.fromString->Option.getOrThrow)

describe("RPC head block checks", () => {
  Async.it(
    "reads every head block's header and asks again only blocks whose bloom may hide our logs",
    async t => {
      await runAtHead(
        ~logs=[
          event(~blockNumber=21),
          // Neither our contract nor our event: the bloom rules it out.
          event(~blockNumber=22, ~address=otherToken, ~topic=approvalTopic),
          // Our contract and our event, but never in one log: the bloom can't
          // tell, so the block is asked again and its empty answer accepted.
          event(~blockNumber=23, ~address=token, ~topic=approvalTopic),
          event(~blockNumber=23, ~logIndex=1, ~address=otherToken),
        ],
        ~height=24,
        ~fault=Honest,
        ~waitFor="21-0-21",
        async (~indexer, ~backfill as _, ~head) => {
          t.expect((
            await indexer->seenIds,
            head,
            // Block 24 holds no event, yet its header was read, so progress
            // there has its timestamp. The mock stamps each block with its
            // number.
            await indexer->progressBlockTime(~atLeast=24),
          )).toEqual((
            ["21-0-21", "3-0-3"],
            [
              "getLogs 21-24",
              "getLogs block 23",
              // An empty block has an all-zero bloom, which some chains serve
              // whatever the block holds, so it says nothing.
              "getLogs block 24",
              "header 21",
              "header 22",
              "header 23",
              "header 24",
            ],
            "24",
          ))
        },
      )
    },
  )

  Async.it(
    "keeps an event a lagging replica answers as empty, retrying until it has the block",
    async t => {
      await runAtHead(
        ~logs=[event(~blockNumber=22), event(~blockNumber=23)],
        ~height=23,
        ~fault=LaggingReplica({block: 22, answers: 2}),
        ~waitFor="23-0-23",
        async (~indexer, ~backfill as _, ~head) => {
          t.expect((
            await indexer->seenIds,
            head->Array.filter(call => call->String.startsWith("getLogs")),
            indexer.allLogsAsJson()->Array.filterMap(
              line =>
                switch line->Dict.get("msg") {
                | Some(String(msg)) if msg->String.includes("hasn't reached block") => Some(msg)
                | _ => None
                },
            ),
          )).toEqual((
            ["22-0-22", "23-0-23", "3-0-3"],
            [
              // The replica's answer: nothing in 22 or 23.
              "getLogs 21-23",
              // The range again, once the source has retried.
              "getLogs 21-23",
              // Block 21 holds no logs at all, and its zero bloom rules nothing
              // out, so each attempt asks for it again.
              "getLogs block 21",
              "getLogs block 21",
              // The replica doesn't know 22, which is the source being behind.
              "getLogs block 22",
              "getLogs block 23",
            ],
            [
              "RPC (127.0.0.1:18741) hasn't reached block 22 on all of its servers yet. This is normal near the latest block and resolves by itself - retrying shortly.",
            ],
          ))
        },
      )
    },
  )

  Async.it(
    "keeps an event a lagging replica answers as empty on a chain that never reorgs",
    async t => {
      await runAtHead(
        ~scenario=noReorgScenario,
        ~logs=[event(~blockNumber=22), event(~blockNumber=24)],
        ~height=24,
        ~fault=LaggingReplica({block: 22, answers: 2}),
        ~waitFor="24-0-24",
        async (~indexer, ~backfill as _, ~head as _) => {
          t.expect(await indexer->seenIds).toEqual(["22-0-22", "24-0-24", "3-0-3"])
        },
      )
    },
  )

  Async.it(
    "keeps an event a lagging replica answers as empty while the backfill reaches the head",
    async t => {
      await runAtHead(
        ~scenario=noReorgScenario,
        ~startupFault=LaggingReplica({block: 19, answers: 2}),
        ~logs=[event(~blockNumber=19)],
        ~height=backfillHeight,
        ~fault=Honest,
        ~waitFor="19-0-19",
        async (~indexer, ~backfill as _, ~head as _) => {
          t.expect(await indexer->seenIds).toEqual(["19-0-19", "3-0-3"])
        },
      )
    },
  )

  Async.it(
    "reads only range ends and event blocks during a backfill more than 200 blocks below the head",
    async t => {
      let backfillHeight = 400
      await runAtHead(
        ~backfillHeight,
        ~logs=[event(~blockNumber=150), event(~blockNumber=401)],
        ~height=401,
        ~fault=Honest,
        ~waitFor="401-0-401",
        async (~indexer as _, ~backfill, ~head as _) => {
          let headers =
            backfill->Array.filterMap(
              call =>
                call->String.startsWith("header ") ? Some(call->blockOf->Array.getUnsafe(0)) : None,
            )
          let rangeEnds =
            backfill
            ->Array.filter(
              call => call->String.startsWith("getLogs ") && !(call->String.includes("block")),
            )
            ->Array.flatMap(blockOf)
          let isEventBlock = block => chain.logs->Array.some(log => log.blockNumber == block)
          t.expect((
            headers->Array.filter(
              block => block < backfillHeight - 200 && !(rangeEnds->Array.includes(block)),
            ),
            Array.fromInitializer(~length=201, i => backfillHeight - 200 + i)->Array.filter(
              block => !(headers->Array.includes(block)),
            ),
          )).toEqual((
            // Read for the event's block fields.
            headers->Array.filter(block => block < backfillHeight - 200 && isEventBlock(block)),
            [],
          ))
        },
      )
    },
  )

  Async.it("keeps an event a range answer leaves out of a block in its middle", async t => {
    await runAtHead(
      ~logs=[event(~blockNumber=22), event(~blockNumber=24)],
      ~height=24,
      ~fault=RangeHole({block: 22, answers: 1}),
      ~waitFor="24-0-24",
      async (~indexer, ~backfill as _, ~head as _) => {
        t.expect(await indexer->seenIds).toEqual(["22-0-22", "24-0-24", "3-0-3"])
      },
    )
  })

  Async.it(
    "keeps an event a lagging replica hides behind an archive refusal of its hash",
    async t => {
      await runAtHead(
        ~logs=[event(~blockNumber=22), event(~blockNumber=23)],
        ~height=23,
        // Longer than a few retries, so giving up on reads by hash would
        // accept the replica's empty answer by number.
        ~fault=LaggingReplicaRefusingAsArchive({block: 22, answers: 12}),
        ~waitFor="23-0-23",
        async (~indexer, ~backfill as _, ~head as _) => {
          t.expect(await indexer->seenIds).toEqual(["22-0-22", "23-0-23", "3-0-3"])
        },
      )
    },
  )

  Async.it(
    "keeps indexing on a provider that refuses reads by hash, asking again by number",
    async t => {
      await runAtHead(
        ~logs=[
          event(~blockNumber=22),
          // The bloom can't rule our logs out, so the block is asked again.
          event(~blockNumber=23, ~address=token, ~topic=approvalTopic),
          event(~blockNumber=23, ~logIndex=1, ~address=otherToken),
          event(~blockNumber=24),
        ],
        ~height=24,
        // From the start, as the provider does: a source that has answered a
        // read by hash takes a later refusal as a block it doesn't know yet.
        ~startupFault=NoBlockHashReads,
        ~fault=NoBlockHashReads,
        ~waitFor="24-0-24",
        async (~indexer, ~backfill as _, ~head) => {
          t.expect((
            await indexer->seenIds,
            // Each block is refused by hash on every attempt, and read by
            // number once the page has been retried long enough.
            [
              "getLogs 21-21",
              "getLogs 23-23",
              "getLogs block 21",
              "getLogs block 23",
            ]->Array.filter(call => !(head->Array.includes(call))),
            indexer.allLogsAsJson()->Array.filterMap(
              line =>
                switch (line->Dict.get("level"), line->Dict.get("msg")) {
                | (Some(String("warn")), Some(String(msg)))
                  if msg->String.includes("by block hash") =>
                  Some(msg)
                | _ => None
                },
            ),
          )).toEqual((
            ["22-0-22", "24-0-24", "3-0-3"],
            [],
            [
              "The RPC provider refused to read logs by block hash, so a block near the head it answered with none of our logs is asked again by number instead. That still catches a range that left a block out, but a node lagging on every answer can drop events unnoticed. A provider that serves eth_getLogs by blockHash (EIP-234) gets the full check.",
            ],
          ))
        },
      )
    },
  )

  Async.it(
    "waits out a provider throttling a read by hash instead of taking it for a node behind the head",
    async t => {
      await runAtHead(
        ~logs=[
          event(~blockNumber=22),
          // The bloom can't rule our logs out, so the block is asked again.
          event(~blockNumber=23, ~address=token, ~topic=approvalTopic),
          event(~blockNumber=23, ~logIndex=1, ~address=otherToken),
          event(~blockNumber=24),
        ],
        ~height=24,
        ~fault=RateLimitedBlockHashReads({block: 23, answers: 1}),
        ~waitFor="24-0-24",
        async (~indexer, ~backfill as _, ~head as _) => {
          t.expect((
            await indexer->seenIds,
            indexer.allLogsAsJson()->Array.filterMap(
              line =>
                switch (
                  line->Dict.get("msg"),
                  line->Dict.get("err"),
                  line->Dict.get("backOffMilliseconds"),
                ) {
                | (Some(String(msg)), _, _) if msg->String.includes("hasn't reached block") =>
                  Some((msg, None))
                | (Some(String(msg)), Some(Object(err)), backoff)
                  if err
                  ->Dict.get("message")
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.mapOr(false, message => message->String.includes("rate limit")) =>
                  Some((msg, backoff->Option.flatMap(JSON.Decode.float)))
                | _ => None
                },
            ),
          )).toEqual((
            ["22-0-22", "24-0-24", "3-0-3"],
            [
              (
                "Failed reading the blocks, transactions or head block re-checks behind the range's logs. Will retry the block range.",
                // The configured backoff, not the quick retries of a node
                // behind the head.
                Some(2000.),
              ),
            ],
          ))
        },
      )
    },
  )

  Async.it(
    "keeps the canonical event when a range answers a block from a replaced branch",
    async t => {
      await runAtHead(
        ~logs=[event(~blockNumber=22), event(~blockNumber=24)],
        ~height=24,
        ~fault=ReplacedBranch({block: 22, answers: 1}),
        ~waitFor="24-0-24",
        async (~indexer, ~backfill as _, ~head as _) => {
          t.expect(await indexer->seenIds).toEqual(["22-0-22", "24-0-24", "3-0-3"])
        },
      )
    },
  )

  Async.it(
    "never accepts the empty answer of a replica that stays behind, failing over instead",
    async t => {
      await runAtHead(
        ~scenario=failoverScenario,
        ~logs=[event(~blockNumber=22)],
        ~height=22,
        ~fault=LaggingReplica({block: 22, answers: 1_000_000}),
        ~waitFor="22-0-22",
        // The source gives a node behind the head about ten seconds of retries
        // before it fails over.
        ~waitForTimeoutMs=30_000.,
        async (~indexer, ~backfill as _, ~head) => {
          t.expect((
            await indexer->seenIds,
            head->Array.some(call => call == "getLogs block 22"),
            fallbackCalls->Array.some(call => call == "getLogs 21-22"),
            indexer.allLogsAsJson()->Array.some(
              line =>
                switch (line->Dict.get("level"), line->Dict.get("msg")) {
                | (Some(String("warn")), Some(String(msg))) =>
                  msg->String.includes("still catching up to block 22")
                | _ => false
                },
            ),
          )).toEqual((["22-0-22", "3-0-3"], true, true, true))
        },
      )
    },
    ~timeout=60_000,
  )
})
