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

describe("Supervisor.plan at the ceiling", () => {
  // A worker is a whole Node process: its own heap, its own copy of the
  // handler modules, its own source clients. A budget that would buy more of
  // them than this spends the surplus widening their pools instead.
  it("Never spends a budget on more than four processes", t => {
    let plan = (~chainCount, ~maxConnections) =>
      Supervisor.plan(~chainIds=chains(chainCount), ~maxConnections)
      ->Option.getOrThrow
      ->Array.map(({maxConnections}: Supervisor.worker) => maxConnections)

    t.expect([
      // Ten chains and the connections for ten workers: four, with the budget
      // spread across them rather than two connections each and the rest
      // unspent.
      plan(~chainCount=10, ~maxConnections=20),
      // The remainder still goes to the earliest workers.
      plan(~chainCount=10, ~maxConnections=22),
      // Below the ceiling nothing changes.
      plan(~chainCount=10, ~maxConnections=6),
    ]).toStrictEqual([[5, 5, 5, 5], [6, 6, 5, 5], [2, 2, 2]])
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
  // A worker's own parse of the project's files is what `envio start` would
  // produce: no chain selection, and no dev run. Both are the command's to say.
  it("Restores what the command decided onto a config it parsed itself", t => {
    let parsedItself = JSON.Object(
      Dict.fromArray([
        ("name", JSON.String("indexer")),
        ("isolatedChains", JSON.Null),
        ("isDev", JSON.Boolean(false)),
      ]),
    )

    t.expect(
      parsedItself->Config.withCommandFields(
        ~chainIds=[1, 137]->Array.map(ChainId.fromInt),
        ~isDev=true,
      ),
    ).toStrictEqual(
      JSON.Object(
        Dict.fromArray([
          ("name", JSON.String("indexer")),
          ("isolatedChains", JSON.Array([JSON.Number(1.), JSON.Number(137.)])),
          ("isDev", JSON.Boolean(true)),
        ]),
      ),
    )
  })

  // `envio dev` keeps the run up once every chain has reached its end block, so
  // the console it serves stays whole. A worker that read the run as a plain
  // `envio start` would exit there and take its chains out of that console.
  it("Keeps a dev run a dev run in the process that drives part of it", t => {
    let devRun = Core.fromUserApi(~schema=perChain, configYaml).config->JSON.parseOrThrow
    let workerConfig =
      devRun
      ->Config.withCommandFields(~chainIds=[1->ChainId.fromInt], ~isDev=true)
      ->Config.fromPublic

    t.expect((
      workerConfig.isDev,
      workerConfig.isolated,
      workerConfig.chainMap->ChainMap.keys,
    )).toStrictEqual((true, true, [1->ChainId.fromInt]))
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

describe("Worker.detect", () => {
  it("Counts as a worker only when forked with the variable and a channel", t => {
    let forked = Dict.fromArray([
      (Worker.envVar, `{"chainIds":[137],"holdRealtime":true,"isDev":true}`),
    ])
    t.expect([
      Worker.detect(~env=forked, ~hasChannel=true),
      // A copy of the variable left in a shell, or a process manager forking
      // with a channel.
      Worker.detect(~env=forked, ~hasChannel=false),
      Worker.detect(~env=Dict.make(), ~hasChannel=true),
    ]).toStrictEqual([
      Some({Worker.chainIds: [137->ChainId.fromInt], holdRealtime: true, isDev: true}),
      None,
      None,
    ])
  })

  // Thrown as the module loads, before anything that could say where a bare
  // schema error came from.
  it("Names the variable when its value isn't a worker config", t => {
    t->Vitest.toThrowErrorEqual(
      () => Worker.detect(~env=Dict.fromArray([(Worker.envVar, "137")]), ~hasChannel=true),
      `Invalid ENVIO_INTERNAL_WORKER: Failed parsing at root. Reason: Expected { chainIds: array<number>; holdRealtime: boolean | undefined; isDev: boolean; }, received 137. It is set by an indexer supervisor for the processes it forks, and isn't meant to be set by hand.`,
    )
  })

  // The supervisor decides whether a run waits; a worker forked before that
  // decision existed reads as one that doesn't.
  it("Takes a config without the hold as one that doesn't wait", t => {
    t.expect(
      Worker.detect(
        ~env=Dict.fromArray([(Worker.envVar, `{"chainIds":[1],"isDev":false}`)]),
        ~hasChannel=true,
      ),
    ).toStrictEqual(
      Some({Worker.chainIds: [1->ChainId.fromInt], holdRealtime: false, isDev: false}),
    )
  })
})

describe("Supervisor.classifyExit", () => {
  let classify = (~code=Null.null, ~signal=Null.null, ~stopping=false) =>
    Supervisor.classifyExit(~code, ~signal, ~stopping)

  it("Reads a signalled worker as a run being stopped, not as one failing", t => {
    t.expect([
      // `systemctl stop` on a unit with the default kill mode signals every
      // process in it, so a worker is told before its supervisor has passed it
      // on. Its exit carries no code at all.
      classify(~signal=Null.make("SIGTERM")),
      // The supervisor's own stop, once it has decided.
      classify(~code=Null.null, ~signal=Null.make("SIGTERM"), ~stopping=true),
      // Indexing to every end block.
      classify(~code=Null.make(0)),
      // The kernel's out-of-memory killer, and a worker that threw.
      classify(~signal=Null.make("SIGKILL")),
      classify(~code=Null.make(1)),
    ]).toStrictEqual([
      Supervisor.Stopping,
      Supervisor.Expected,
      Supervisor.Expected,
      Supervisor.Failed,
      Supervisor.Failed,
    ])
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

describe("Supervisor.configuredChains", () => {
  it("Draws the run's chains at their configured blocks, with nothing indexed", t => {
    let config = TestConfig.fromUserApi(`
name: test-config
chains:
  - id: 1
    start_block: 100
    end_block: 500
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Poap
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`)

    t.expect(
      Supervisor.configuredChains(config)->Array.map(
        chain => (
          chain.chainId->ChainId.toString,
          chain.startBlock,
          chain.endBlock,
          chain.poweredByHyperSync,
          chain.progressBlockNumber,
          chain.numEventsProcessed,
          chain.isReady,
        ),
      ),
    ).toStrictEqual([
      ("1", 100, Some(500), true, -1, 0., false),
      ("137", 0, None, false, -1, 0., false),
    ])
  })
})
