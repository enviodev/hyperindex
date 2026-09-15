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
      Some([("1,3", 2), ("2,4", 2)]),
      Some([("1", 3), ("2", 3), ("3", 2), ("4", 2)]),
      Some([("1", 4), ("2", 4), ("3", 4)]),
      None,
    ])
  })
})

describe("Supervisor.planForRun", () => {
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
  it("Holds back a chunk's partial tail until the rest of the line arrives", t => {
    let split = Supervisor.makeLineSplitter()

    t.expect([
      split("one\ntw"),
      split("o\nthree\n"),
      split(""),
      split("four\nfive\n"),
    ]).toStrictEqual([["one\n"], ["two\n", "three\n"], [], ["four\n", "five\n"]])
  })

  it("Narrows the config it hands a worker to that worker's chains", t => {
    let configJson = JSON.Object(
      Dict.fromArray([("name", JSON.String("indexer")), ("isolatedChains", JSON.Null)]),
    )

    t.expect(
      configJson->Supervisor.configForWorker(
        ~worker={chainIds: [1, 137]->Array.map(ChainId.fromInt), maxConnections: 2},
      ),
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
