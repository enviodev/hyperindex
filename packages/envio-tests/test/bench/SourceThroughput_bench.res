open Vitest

// Wall time for the whole indexer to fetch, decode and route a served chain to
// its end block: one chain over HyperSync, one over RPC, each against a local
// server. Handlers do nothing, so the time is the fetch path and the loop
// around it. Run with `pnpm bench`; results append to .bench-results.txt.
// Compare runs on the same machine only.

let token = "0x4444444444444444444444444444444444444444"
let transferSig = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let holders = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
]

let blocks = 3_000
let logsPerBlock = 10

let logs = Array.fromInitializer(~length=blocks * logsPerBlock, index => {
  let holder = offset =>
    holders
    ->Array.getUnsafe(mod(index + offset, holders->Array.length))
    ->ServedEvmChain.addressTopic
  let log: ServedEvmChain.log = {
    blockNumber: index / logsPerBlock + 1,
    logIndex: mod(index, logsPerBlock),
    address: token,
    topics: [transferSig, holder(0), holder(1)],
    data: ServedEvmChain.uintTopic(index->BigInt.fromInt),
  }
  log
})

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18691,
  ~rpcPort=18692,
  ~height=blocks,
  ~logs,
)

let scenario = (~hyperSync, ~rpc) =>
  Scenario.make(
    ~configYaml=`
name: source-throughput
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
        ~hyperSync,
        ~rpc,
        ~contracts=`
      - name: Token
        address: "${token}"`,
        ~rpcOptions=`
      initial_block_interval: 1000
      interval_ceiling: 1000`,
      )}
`,
    ~schema=ServedEvmChain.routedSchema,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`,
  )

let hyperSyncScenario = scenario(~hyperSync=[1], ~rpc=[])
let rpcScenario = scenario(~hyperSync=[], ~rpc=[1])

@module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

// Vitest keeps a test's console to itself, so results go to a file.
let resultsFile = ".bench-results.txt"

let measure = async (name, scenario) => {
  // Real time: the measurement itself.
  let started = Performance.now()
  let exited = ref(false)
  await scenario->Scenario.run(
    ~yamlSources=true,
    ~onExit=() => exited := true,
    async (~indexer as _, ~source as _) =>
      await Scenario.waitUntil(
        () => exited.contents,
        ~message="the chain to reach its end block",
        ~timeoutMs=300_000.,
      ),
  )
  let seconds = started->Performance.secondsSince
  let logCount = logs->Array.length->Int.toFloat
  appendFileSync(
    resultsFile,
    `${name}: ${logCount->Float.toFixed(~digits=0)} logs in ${seconds->Float.toFixed(
        ~digits=2,
      )}s, ${(logCount /. seconds)->Float.toFixed(~digits=0)} logs/s\n`,
  )
}

describe("Source throughput", () => {
  Async.it("HyperSync", async _ => await measure("HyperSync", hyperSyncScenario), ~timeout=400_000)
  Async.it("RPC", async _ => await measure("RPC", rpcScenario), ~timeout=400_000)
})
