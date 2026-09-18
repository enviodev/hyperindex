open Vitest

let chains = n => Array.make(~length=n, 0)->Array.mapWithIndex((_, i) => (i + 1)->ChainId.fromInt)

describe("Supervisor.plan", () => {
  it("Splits only when the budget affords two workers, and spends all of it", t => {
    let plan = (~chainCount, ~maxConnections) =>
      Supervisor.plan(~chainIds=chains(chainCount), ~maxConnections)->Option.map(
        workers =>
          workers->Array.map(
            ({chainIds, maxConnections}: Supervisor.worker) => (
              chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(","),
              maxConnections,
            ),
          ),
      )

    t.expect([
      // The default budget is what one process uses today, so nothing splits.
      plan(~chainCount=4, ~maxConnections=2),
      plan(~chainCount=4, ~maxConnections=3),
      plan(~chainCount=4, ~maxConnections=4),
      // More budget than chains: the surplus widens every worker's pool
      // instead of going unused.
      plan(~chainCount=4, ~maxConnections=10),
      plan(~chainCount=3, ~maxConnections=12),
      // A single chain has nothing to split against, whatever the budget.
      plan(~chainCount=1, ~maxConnections=100),
    ]).toStrictEqual([
      None,
      None,
      Some([("1,4", 2), ("2,3", 2)]),
      Some([("1", 3), ("2", 3), ("3", 2), ("4", 2)]),
      Some([("1", 4), ("2", 4), ("3", 4)]),
      None,
    ])
  })
})

describe("Supervisor.plan on the default budget", () => {
  // Splitting a run costs connections the operator didn't ask to spend, so the
  // budget they didn't set is the one a single process has always used.
  it("Keeps a run in one process until the budget is raised", t => {
    t.expect(Supervisor.plan(~chainIds=chains(4), ~maxConnections=Env.Db.maxConnections)).toBe(None)
  })
})

describe("Supervisor.plan dealing order", () => {
  let assignment = (~chainIds, ~maxConnections) =>
    Supervisor.plan(~chainIds=chainIds->Array.map(ChainId.fromInt), ~maxConnections)
    ->Option.getOrThrow
    ->Array.map(worker => worker.chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(","))

  it("Deals chains in config order, reversing direction each pass", t => {
    t.expect([
      // The first two lead different workers; the worker that took the first
      // picks up the last. Config order is the ranking, not the chain ids.
      assignment(~chainIds=[8453, 56, 42161, 1], ~maxConnections=4),
      // Three workers take the first three, then fold back.
      assignment(~chainIds=[1, 56, 137, 8453, 42161, 10], ~maxConnections=6),
      // An odd count leaves the fold short: the last chain lands mid-pass.
      assignment(~chainIds=[1, 56, 137, 8453, 42161], ~maxConnections=4),
    ]).toStrictEqual([
      ["8453,1", "56,42161"],
      ["1,10", "56,42161", "137,8453"],
      ["1,8453,42161", "56,137"],
    ])
  })
})

let configYaml = `
name: supervised-run
disable_default_cross_chain: true
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Counters
        address: "0x2222222222222222222222222222222222222222"
`

let config = (~schema, ~isolatedChains=?) => {
  let json = Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow
  switch (json, isolatedChains) {
  | (Object(obj), Some(chainIds)) => obj->Dict.set("isolatedChains", JSON.Encode.array(chainIds))
  | _ => ()
  }
  Config.fromPublic(json)
}

let perChain = `
type Counter {
  id: ID!
  count: BigInt!
}
`
let crossChain = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

describe("Supervisor.planForRun", () => {
  it("Splits a per-chain schema, and leaves everything else in one process", t => {
    let workerChains = (~schema, ~maxConnections, ~isolatedChains=?) =>
      Supervisor.planForRun(~config=config(~schema, ~isolatedChains?), ~maxConnections)->Option.map(
        workers =>
          workers->Array.map(
            worker => worker.chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(","),
          ),
      )

    t.expect([
      workerChains(~schema=perChain, ~maxConnections=4),
      // An entity shared across chains can't be split: workers would each
      // advance their own checkpoint over rows the others reach.
      workerChains(~schema=crossChain, ~maxConnections=4),
      // The budget one process uses today buys nothing to split with.
      workerChains(~schema=perChain, ~maxConnections=2),
      // Already one chain's process: whoever started it owns the layout.
      workerChains(~schema=perChain, ~maxConnections=100, ~isolatedChains=[JSON.Number(1.)]),
    ]).toStrictEqual([Some(["1", "137"]), None, None, None])
  })
})

describe("Supervisor worker plumbing", () => {
  it("Narrows a config it parsed itself to the chains it was given", t => {
    let configJson = JSON.Object(
      Dict.fromArray([("name", JSON.String("indexer")), ("isolatedChains", JSON.Null)]),
    )

    t.expect(
      configJson->Config.withIsolatedChains(~chainIds=[1, 137]->Array.map(ChainId.fromInt)),
    ).toStrictEqual(
      JSON.Object(
        Dict.fromArray([
          ("name", JSON.String("indexer")),
          ("isolatedChains", JSON.Array([JSON.Number(1.), JSON.Number(137.)])),
        ]),
      ),
    )
  })

  it("Gives every worker a log file of its own", t => {
    t.expect([
      Supervisor.logFilePath(~workerIndex=0, ~path="logs/envio.log"),
      Supervisor.logFilePath(~workerIndex=1, ~path="logs/envio.log"),
      // A dot in a directory name is not an extension.
      Supervisor.logFilePath(~workerIndex=1, ~path="./logs/envio"),
      Supervisor.logFilePath(~workerIndex=2, ~path="envio"),
    ]).toStrictEqual([
      "logs/envio.worker-0.log",
      "logs/envio.worker-1.log",
      "./logs/envio.worker-1",
      "envio.worker-2",
    ])
  })
})

describe("Config.logContext", () => {
  it("Names the one chain an isolated process drives, and nothing otherwise", t => {
    t.expect([
      // This process drives one of the schema's chains while siblings drive the rest.
      config(~schema=perChain, ~isolatedChains=[JSON.Number(137.)])->Config.logContext,
      // Several chains have no single owner to name.
      config(
        ~schema=perChain,
        ~isolatedChains=[JSON.Number(1.), JSON.Number(137.)],
      )->Config.logContext,
      // One process driving every chain: chain-scoped lines already name theirs,
      // and the rest belong to the run as a whole.
      config(~schema=perChain)->Config.logContext,
      config(~schema=crossChain)->Config.logContext,
    ]).toStrictEqual([
      Some(Dict.fromArray([("chainId", JSON.Number(137.))])),
      None,
      None,
      None,
    ])
  })
})

describe("Worker.detect", () => {
  it("Counts as a worker only when forked with the variable and a channel", t => {
    let forked = Dict.fromArray([(Worker.envVar, `{"chainIds":[137],"holdRealtime":true}`)])
    t.expect([
      Worker.detect(~env=forked, ~hasChannel=true),
      // A copy of the variable left in a shell, or a process manager forking
      // with a channel.
      Worker.detect(~env=forked, ~hasChannel=false),
      Worker.detect(~env=Dict.make(), ~hasChannel=true),
    ]).toStrictEqual([
      Some({Worker.chainIds: [137->ChainId.fromInt], holdRealtime: true}),
      None,
      None,
    ])
  })

  // Thrown as the module loads, before anything that could say where a bare
  // schema error came from.
  it("Names the variable when its value isn't a worker config", t => {
    t->Vitest.toThrowErrorEqual(
      () => Worker.detect(~env=Dict.fromArray([(Worker.envVar, "137")]), ~hasChannel=true),
      `Invalid ENVIO_INTERNAL_WORKER: Failed parsing at root. Reason: Expected { chainIds: array<number>; holdRealtime: boolean | undefined; }, received 137. It is set by an indexer supervisor for the processes it forks, and isn't meant to be set by hand.`,
    )
  })

  // The supervisor decides whether a run waits; a worker forked before that
  // decision existed reads as one that doesn't.
  it("Takes a config without the hold as one that doesn't wait", t => {
    t.expect(
      Worker.detect(
        ~env=Dict.fromArray([(Worker.envVar, `{"chainIds":[1]}`)]),
        ~hasChannel=true,
      ),
    ).toStrictEqual(Some({Worker.chainIds: [1->ChainId.fromInt], holdRealtime: false}))
  })
})

describe("Supervisor.syncCache", () => {
  Async.it("Dumps once for requests that overlap, and again for a later one", async t => {
    let dumps = ref(0)
    let dump = () => {
      dumps := dumps.contents + 1
      Utils.delay(20)
    }

    let first = Supervisor.syncCache(~dump)
    let second = Supervisor.syncCache(~dump)
    await first
    await second
    await Supervisor.syncCache(~dump)

    t.expect(dumps.contents).toBe(2)
  })
})

describe("Supervisor.isRunAtHead", () => {
  let snapshot = (~hasArrivedAtHead): Metrics.t => {
    ...TestChainMetrics.emptySnapshot,
    hasArrivedAtHead,
  }

  it("Holds the run until every worker has arrived", t => {
    t.expect([
      // A worker that hasn't reported yet drives chains nobody can see. Reading
      // the run as arrived here would release it on a partial view.
      [snapshot(~hasArrivedAtHead=true)]->Supervisor.isRunAtHead(~workerCount=2),
      [
        snapshot(~hasArrivedAtHead=true),
        snapshot(~hasArrivedAtHead=false),
      ]->Supervisor.isRunAtHead(~workerCount=2),
      [
        snapshot(~hasArrivedAtHead=true),
        snapshot(~hasArrivedAtHead=true),
      ]->Supervisor.isRunAtHead(~workerCount=2),
    ]).toStrictEqual([false, false, true])
  })
})
