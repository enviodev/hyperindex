open Vitest

// One page reads the listed selections that share a filter with one merged
// eth_getLogs and picks each selection's own logs out of the answer, so a chain
// of many contracts costs one read per page instead of one per contract. The
// local server records the filter every read carried, so a merged read is seen
// as the addresses and topics it asked for.
let rpcPort = 18751

let tokenA = "0x1000000000000000000000000000000000000001"
let tokenB = "0x2000000000000000000000000000000000000002"
let tokenC = "0x3000000000000000000000000000000000000003"
let tokenD = "0x4000000000000000000000000000000000000004"
let tokenE = "0x5000000000000000000000000000000000000005"
let tokenF = "0x6000000000000000000000000000000000000006"
let holder = "0x7000000000000000000000000000000000000007"

let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

let event = (
  ~blockNumber,
  ~logIndex=0,
  ~address=tokenA,
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

// How the provider answers eth_getLogs for a while.
type fault =
  | Honest
  // A filter with more than `maxAddresses` addresses is refused the way
  // go-ethereum refuses one over its per-position limit.
  | FilterSizeLimit({maxAddresses: int})
  // A range read carrying more than one address that touches `block` is
  // refused for its result count, the way a dense block is.
  | MergedResultCap({block: int})

type chain = {mutable height: int, mutable logs: array<ServedEvmChain.log>, mutable fault: fault}
let chain = {height: backfillHeight, logs: [], fault: Honest}

// Every eth_getLogs and eth_getBlockByNumber the provider was asked. A log read
// carries the filter it asked for: `getLogs <from>-<to> a=<n> t=<...>` for a
// range, `getLogs block <n> a=<n> t=<...>` for a read by hash. `a` counts the
// filter's addresses and `t` counts the values at each topic position, `*` for a
// match-any position.
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

let filterBlocks = filter =>
  switch filter->Dict.get("blockHash") {
  | Some(hash) =>
    let block = hash->ServedEvmChain.quantity
    (true, block, block)
  | None => (
      false,
      filter->Dict.getUnsafe("fromBlock")->ServedEvmChain.quantity,
      filter->Dict.getUnsafe("toBlock")->ServedEvmChain.quantity,
    )
  }

let addressCount = filter =>
  switch filter->Dict.get("address") {
  | Some(JSON.Array(addresses)) => addresses->Array.length
  | _ => 0
  }

let topicLabel = filter =>
  switch filter->Dict.get("topics") {
  | Some(JSON.Array(positions)) =>
    positions
    ->Array.map(position =>
      switch position {
      | JSON.Null => "*"
      | JSON.Array(values) => values->Array.length->Int.toString
      | _ => "*"
      }
    )
    ->Array.join(",")
  | _ => "*"
  }

let logLabel = filter => {
  let (byHash, fromBlock, toBlock) = filter->filterBlocks
  let suffix = ` a=${filter->addressCount->Int.toString} t=${filter->topicLabel}`
  byHash
    ? `getLogs block ${fromBlock->Int.toString}${suffix}`
    : `getLogs ${fromBlock->Int.toString}-${toBlock->Int.toString}${suffix}`
}

let getLogs = (request, filter, ~fault, ~calls) => {
  let (_, fromBlock, toBlock) = filter->filterBlocks
  calls->Array.push(filter->logLabel)->ignore
  let matched = chain.logs->Array.filter(log => ServedEvmChain.rpcFilterMatches(filter, log))
  let honest = () =>
    envelope(request, "result", JSON.Array(matched->Array.map(log => ServedEvmChain.rpcLog(log))))
  let touches = block => fromBlock <= block && block <= toBlock
  let error = (code, message) =>
    envelope(
      request,
      "error",
      JSON.Object(
        dict{"code": JSON.Number(code), "message": JSON.String(message)},
      ),
    )
  switch fault {
  | FilterSizeLimit({maxAddresses}) if filter->addressCount > maxAddresses =>
    error(-32000., "exceed max addresses or topics per search position")
  | MergedResultCap({block}) if filter->addressCount > 1 && touches(block) =>
    error(-32005., "query returned more than 10000 results")
  | _ => honest()
  }
}

let serve = (~fault, ~calls) =>
  MockRpcServer.start(~port=rpcPort, ~handler=body => {
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

let getServer = RpcE2eChain.serveDuringSuite(() => serve(~fault=() => chain.fault, ~calls))

let rpc = `
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      polling_interval: 10`

// Six contracts, one event each: six listed selections a page merges into one
// read.
let sixContractScenario = Scenario.make(
  ~configYaml=`
name: rpc-merged-range-reads-six-contracts
contracts:
  - name: TokenA
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenB
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenC
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenD
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenE
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenF
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1337
    rpc:${rpc}
    start_block: 1
    max_reorg_depth: 5
    contracts:
      - name: TokenA
        address: "${tokenA}"
      - name: TokenB
        address: "${tokenB}"
      - name: TokenC
        address: "${tokenC}"
      - name: TokenD
        address: "${tokenD}"
      - name: TokenE
        address: "${tokenE}"
      - name: TokenF
        address: "${tokenF}"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "TokenA", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenB", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenC", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenD", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenE", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenF", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});
`,
  // A real RPC source against a local server: its requests resolve on real I/O.
  ~virtualTime=false,
)

// Two contracts on two different events: one merged read covers both, and each
// selection gets only its own logs.
let twoEventScenario = Scenario.make(
  ~configYaml=`
name: rpc-merged-range-reads-two-events
contracts:
  - name: TokenA
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenB
    events:
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1337
    rpc:${rpc}
    start_block: 1
    max_reorg_depth: 5
    contracts:
      - name: TokenA
        address: "${tokenA}"
      - name: TokenB
        address: "${tokenB}"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "TokenA", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenB", event: "Approval" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});
`,
  // A real RPC source against a local server: its requests resolve on real I/O.
  ~virtualTime=false,
)

// A `where` filter on an indexed parameter constrains a topic position past
// topic0, so that selection keeps its own read.
let whereFilterScenario = Scenario.make(
  ~configYaml=`
name: rpc-merged-range-reads-where-filter
contracts:
  - name: TokenA
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenB
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenC
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1337
    rpc:${rpc}
    start_block: 1
    max_reorg_depth: 5
    contracts:
      - name: TokenA
        address: "${tokenA}"
      - name: TokenB
        address: "${tokenB}"
      - name: TokenC
        address: "${tokenC}"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

const holder = "${holder}";

indexer.onEvent({ contract: "TokenA", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenB", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent(
  { contract: "TokenC", event: "Transfer", where: { params: { to: holder } } },
  async ({ event, context }) => {
    context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
  },
);
`,
  // A real RPC source against a local server: its requests resolve on real I/O.
  ~virtualTime=false,
)

// A wildcard event is address-free, so it keeps its own read while the listed
// selections merge.
let wildcardScenario = Scenario.make(
  ~configYaml=`
name: rpc-merged-range-reads-wildcard
contracts:
  - name: TokenA
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: TokenB
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: AnyApproval
    events:
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1337
    rpc:${rpc}
    start_block: 1
    max_reorg_depth: 5
    contracts:
      - name: TokenA
        address: "${tokenA}"
      - name: TokenB
        address: "${tokenB}"
      - name: AnyApproval
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "TokenA", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent({ contract: "TokenB", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
});

indexer.onEvent(
  { contract: "AnyApproval", event: "Approval", wildcard: true },
  async ({ event, context }) => {
    context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}-\${event.params.value}\` });
  },
);
`,
  // A real RPC source against a local server: its requests resolve on real I/O.
  ~virtualTime=false,
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

let takeCalls = () => {
  let taken = calls->Array.toSorted(String.compare)
  calls->Utils.Array.clearInPlace
  taken
}

let rangeReads = calls =>
  calls->Array.filter(call =>
    call->String.startsWith("getLogs ") && !(call->String.includes("block "))
  )

// Indexes up to the backfill height with the provider answering honestly, then
// lets the chain grow to `height` with `logs` and the provider answering the way
// `fault` says, and runs `body` once the event `waitFor` names is indexed.
let runAtHead = async (
  ~scenario,
  ~logs,
  ~height,
  ~fault,
  ~waitFor,
  ~backfillHeight=backfillHeight,
  body,
) => {
  let _ = getServer()
  chain.height = backfillHeight
  chain.logs = [event(~blockNumber=3), ...logs]
  chain.fault = Honest
  calls->Utils.Array.clearInPlace
  await scenario->Scenario.run(~yamlSources=true, async (~indexer, ~source as _) => {
    await indexer->waitForSeen("3-0-3")
    await indexer.waitUntilReady()
    let _ = takeCalls()
    chain.fault = fault
    chain.height = height
    await indexer->waitForSeen(waitFor)
    await body(~indexer, ~head=takeCalls())
  })
}

describe("RPC merged range reads", () => {
  Async.it("reads a quiet head range once for six contracts", async t => {
    await runAtHead(
      ~scenario=sixContractScenario,
      ~logs=[event(~blockNumber=24)],
      ~height=24,
      ~fault=Honest,
      ~waitFor="24-0-24",
      async (~indexer, ~head) => {
        t.expect((await indexer->seenIds, head->rangeReads)).toEqual((
          ["24-0-24", "3-0-3"],
          // Six contracts, one topic0, no constraint past it: one group.
          ["getLogs 21-24 a=6 t=1"],
        ))
      },
    )
  })

  Async.it("gives each contract only its own logs out of one merged answer", async t => {
    await runAtHead(
      ~scenario=twoEventScenario,
      ~logs=[
        event(~blockNumber=22),
        event(~blockNumber=22, ~logIndex=1, ~address=tokenB, ~topic=approvalTopic),
        event(~blockNumber=22, ~logIndex=2, ~address=tokenA, ~topic=approvalTopic),
        event(~blockNumber=22, ~logIndex=3, ~address=tokenB),
      ],
      ~height=24,
      ~fault=Honest,
      ~waitFor="22-0-22",
      async (~indexer, ~head) => {
        t.expect((await indexer->seenIds, head->rangeReads)).toEqual((
          // TokenA only gets its Transfer, TokenB only its Approval; TokenA's
          // Approval and TokenB's Transfer match no selection and are dropped.
          ["22-0-22", "22-1-22", "3-0-3"],
          ["getLogs 21-24 a=2 t=2"],
        ))
      },
    )
  })

  Async.it("keeps a where-filtered event in its own read", async t => {
    await runAtHead(
      ~scenario=whereFilterScenario,
      ~logs=[event(~blockNumber=24)],
      ~height=24,
      ~fault=Honest,
      ~waitFor="24-0-24",
      async (~indexer as _, ~head) => {
        t.expect(head->rangeReads).toEqual([
          "getLogs 21-24 a=1 t=1,*,1",
          "getLogs 21-24 a=2 t=1",
        ])
      },
    )
  })

  Async.it(
    "reads each selection on its own once the provider refuses the size of the merged filter",
    async t => {
      let _ = getServer()
      chain.height = backfillHeight
      chain.logs = [event(~blockNumber=3), event(~blockNumber=22), event(~blockNumber=24)]
      chain.fault = Honest
      calls->Utils.Array.clearInPlace
      await sixContractScenario->Scenario.run(~yamlSources=true, async (~indexer, ~source as _) => {
        await indexer->waitForSeen("3-0-3")
        await indexer.waitUntilReady()
        let _ = takeCalls()
        chain.fault = FilterSizeLimit({maxAddresses: 1})
        chain.height = 22
        await indexer->waitForSeen("22-0-22")
        let step1 = takeCalls()
        chain.height = 24
        await indexer->waitForSeen("24-0-24")
        let step2 = takeCalls()
        t.expect((
          await indexer->seenIds,
          step1->Array.filter(call => call->String.startsWith("getLogs")),
          step2->Array.filter(call => call->String.startsWith("getLogs")),
          indexer.allLogsAsJson()->Array.filter(
            line =>
              switch line->Dict.get("msg") {
              | Some(String(msg)) if msg->String.includes("refused one eth_getLogs") => true
              | _ => false
              },
          )->Array.length,
        )).toEqual((
          ["22-0-22", "24-0-24", "3-0-3"],
          [
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=1 t=1",
            "getLogs 21-22 a=6 t=1",
          ],
          [
            "getLogs 23-24 a=1 t=1",
            "getLogs 23-24 a=1 t=1",
            "getLogs 23-24 a=1 t=1",
            "getLogs 23-24 a=1 t=1",
            "getLogs 23-24 a=1 t=1",
            "getLogs 23-24 a=1 t=1",
          ],
          1,
        ))
      })
    },
  )

  Async.it("reads one dense block for each selection and merges again on the next page", async t => {
    await runAtHead(
      ~scenario=sixContractScenario,
      ~logs=[event(~blockNumber=22), event(~blockNumber=24)],
      ~height=24,
      ~fault=MergedResultCap({block: 22}),
      ~waitFor="24-0-24",
      async (~indexer, ~head) => {
        let reads = head->rangeReads
        t.expect((
          await indexer->seenIds,
          reads->Array.filter(call => call->String.includes("getLogs 22-22 a=1")),
          reads->Array.getUnsafe(reads->Array.length - 1),
        )).toEqual((
          ["22-0-22", "24-0-24", "3-0-3"],
          [
            "getLogs 22-22 a=1 t=1",
            "getLogs 22-22 a=1 t=1",
            "getLogs 22-22 a=1 t=1",
            "getLogs 22-22 a=1 t=1",
            "getLogs 22-22 a=1 t=1",
            "getLogs 22-22 a=1 t=1",
          ],
          "getLogs 23-24 a=6 t=1",
        ))
      },
    )
  })

  Async.it("keeps address-free selections apart from the merged read", async t => {
    await runAtHead(
      ~scenario=wildcardScenario,
      ~logs=[event(~blockNumber=22, ~address=tokenA), event(~blockNumber=22, ~logIndex=1, ~address=holder, ~topic=approvalTopic)],
      ~height=24,
      ~fault=Honest,
      ~waitFor="22-0-22",
      async (~indexer as _, ~head) => {
        t.expect(head->rangeReads).toEqual(["getLogs 21-24 a=0 t=1", "getLogs 21-24 a=2 t=1"])
      },
    )
  })
})
