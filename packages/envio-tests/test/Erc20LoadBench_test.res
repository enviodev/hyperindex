open Vitest

// A load benchmark rather than a test: the erc20 template's handlers over a
// synthetic token history, served by a local HyperSync server into the real
// indexer loop and Postgres. Skipped unless ENVIO_BENCH is set; the numbers it
// reports land in ENVIO_BENCH_OUT.

let env = NodeJs.Process.process.env
let envInt = (name, fallback) =>
  env->Dict.get(name)->Option.flatMap(v => v->Int.fromString)->Option.getOr(fallback)

let transfers = envInt("ENVIO_BENCH_TRANSFERS", 100_000)
// Out of 100 transfers, how many send to an address never seen before.
let newReceiverPercent = envInt("ENVIO_BENCH_NEW_PERCENT", 30)
let approvalPercent = envInt("ENVIO_BENCH_APPROVAL_PERCENT", 10)
let logsPerBlock = envInt("ENVIO_BENCH_LOGS_PER_BLOCK", 10)

let token = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let approvalSighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
let zero = "0x0000000000000000000000000000000000000000"

let address = n => "0x" ++ (n + 1)->Int.toString(~radix=16)->String.padStart(40, "a")

// A fixed Lehmer generator, so every run indexes the same history.
let seed = ref(42.)
let random = () => {
  seed := Float.mod(seed.contents *. 16807., 2147483647.)
  seed.contents /. 2147483647.
}

let logs = {
  let holders = ref(0)
  // Skewed toward early holders, the way a few accounts dominate a token.
  let pickHolder = () => (holders.contents->Int.toFloat *. random() *. random())->Float.toInt
  let logs: array<ServedEvmChain.log> = []
  let total = transfers + transfers * approvalPercent / 100
  for i in 0 to total - 1 {
    let blockNumber = 1 + i / logsPerBlock
    let logIndex = mod(i, logsPerBlock)
    if holders.contents == 0 || random() *. 100. < (100 - approvalPercent)->Int.toFloat {
      let from = holders.contents == 0 ? zero : address(pickHolder())
      let to = if holders.contents == 0 || random() *. 100. < newReceiverPercent->Int.toFloat {
        holders := holders.contents + 1
        address(holders.contents - 1)
      } else {
        address(pickHolder())
      }
      logs
      ->Array.push({
        blockNumber,
        logIndex,
        address: token,
        topics: [
          transferSighash,
          from->ServedEvmChain.addressTopic,
          to->ServedEvmChain.addressTopic,
        ],
        data: 1000n->ServedEvmChain.uintTopic,
      })
      ->ignore
    } else {
      // Owners are mostly fresh too: approving before ever holding is common.
      let owner = random() < 0.5 ? address(pickHolder()) : address(1_000_000 + i)
      logs
      ->Array.push({
        blockNumber,
        logIndex,
        address: token,
        topics: [
          approvalSighash,
          owner->ServedEvmChain.addressTopic,
          address(pickHolder())->ServedEvmChain.addressTopic,
        ],
        data: 5n->ServedEvmChain.uintTopic,
      })
      ->ignore
    }
  }
  logs
}

let height = (logs->Array.length - 1) / logsPerBlock + 1

let served = ServedEvmChain.serveDuringSuite(~hyperSyncPort=18731, ~rpcPort=18732, ~height, ~logs)

let schema = `
type Account {
  id: ID!
  approvals: [Approval!]! @derivedFrom(field: "owner")
  balance: BigInt!
}

type Approval {
  id: ID!
  amount: BigInt!
  owner: Account!
  spender: Account!
}
`

let handlers = `
import { indexer, type Account, type Approval } from "envio";

indexer.onEvent(
  { contract: "ERC20", event: "Approval" },
  async ({ event, context }) => {
    let ownerAccount = await context.Account.get(event.params.owner);
    if (ownerAccount === undefined) {
      let accountObject: Account = { id: event.params.owner, balance: 0n };
      context.Account.set(accountObject);
    }
    let approvalObject: Approval = {
      id: event.params.owner + "-" + event.params.spender,
      amount: event.params.value,
      owner_id: event.params.owner,
      spender_id: event.params.spender,
    };
    context.Approval.set(approvalObject);
  },
);

indexer.onEvent(
  { contract: "ERC20", event: "Transfer" },
  async ({ event, context }) => {
    let [senderAccount, receiverAccount] = await Promise.all([
      context.Account.get(event.params.from),
      context.Account.get(event.params.to),
    ]);
    if (senderAccount === undefined) {
      context.Account.set({ id: event.params.from, balance: 0n - event.params.value });
    } else {
      context.Account.set({ id: senderAccount.id, balance: senderAccount.balance - event.params.value });
    }
    if (receiverAccount === undefined) {
      context.Account.set({ id: event.params.to, balance: event.params.value });
    } else {
      context.Account.set({ id: receiverAccount.id, balance: receiverAccount.balance + event.params.value });
    }${env->Dict.get("ENVIO_BENCH_GETWHERE")->Option.isSome
    ? `
    const approvals = await context.Approval.getWhere({ owner_id: { _eq: event.params.to } });
    if (approvals.length > 1000) throw new Error("unreachable");`
    : ""}
  },
);
`

let configYaml = (~chains) =>
  `
name: erc20-load-bench
disable_default_cross_chain: true
strict_hex_type: true
rollback_on_reorg: false
full_batch_size: ${envInt("ENVIO_BENCH_BATCH_SIZE", 5000)->Int.toString}
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:${chains}
`

let contractsYaml = `
      - name: ERC20
        address: "${token}"`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=configYaml(
    ~chains=served->ServedEvmChain.chainsYaml(~hyperSync=[1], ~rpc=[], ~contracts=contractsYaml),
  ),
  ~schema,
  ~handlers,
)

// No end block: the first run indexes what the server holds then follows its
// head, so a restart can resume it and index the rest.
let resumeScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=configYaml(
    ~chains=`
  - id: 1
    start_block: 1
    hypersync_config:
      url: ${ServedEvmChain.url(served.hyperSyncPort)}
    contracts:${contractsYaml}`,
  ),
  ~schema,
  ~handlers,
)

let metricNames = [
  "envio_storage_load_seconds",
  "envio_storage_load_total",
  "envio_storage_load_where_size",
  "envio_storage_load_size",
  "envio_preload_seconds",
  "envio_processing_seconds",
  "envio_storage_write_seconds",
]

let report = async (indexer: IndexerRunner.t, ~seconds) => {
  let metrics = Dict.make()
  for i in 0 to metricNames->Array.length - 1 {
    let name = metricNames->Array.getUnsafe(i)
    metrics->Dict.set(name, (await indexer.metric(name))->(Utils.magic: 'a => JSON.t))
  }
  let accounts: array<{"id": string, "balance": JSON.t}> = await indexer.query("Account")
  let approvals: array<{"id": string}> = await indexer.query("Approval")
  // Any read the filters answered wrongly shows up as a different ledger.
  let checksum =
    accounts
    ->Array.map(account => account["id"] ++ "=" ++ account["balance"]->String.make)
    ->Array.concat(approvals->Array.map(approval => approval["id"]))
    ->Array.toSorted(String.compare)
    ->Array.join(",")
  BloomFilter.hashKey(checksum)
  let checksum = BloomFilter.hash1.contents
  let report = {
    "label": env->Dict.get("ENVIO_BENCH_LABEL")->Option.getOr(""),
    "checksum": checksum,
    "transfers": transfers,
    "logs": logs->Array.length,
    "accounts": accounts->Array.length,
    "seconds": seconds,
    "metrics": metrics,
  }
  switch env->Dict.get("ENVIO_BENCH_OUT") {
  | Some(path) =>
    await NodeJs.Fs.Promises.appendFile(
      ~filepath=NodeJs.Path.resolve([path]),
      ~content=report->JSON.stringifyAny->Option.getOrThrow ++ "\n",
    )
  | None => ()
  }
}

let progressBlock = async (indexer: IndexerRunner.t) =>
  switch await indexer.metric("envio_progress_block") {
  | [{value}] => value->Int.fromString->Option.getOr(0)
  | _ => 0
  }

let rec waitForProgress = async (indexer, ~block, ~deadline) =>
  if (await progressBlock(indexer)) < block {
    if Date.now() > deadline {
      JsError.throwWithMessage(`Timed out waiting for block ${block->Int.toString}`)
    }
    await Utils.delay(20)
    await waitForProgress(indexer, ~block, ~deadline)
  }

let mode = env->Dict.get("ENVIO_BENCH")

describe("erc20 load bench", () => {
  Async.it_skipIf(mode !== Some("fresh"))("indexes the synthetic history", async _ => {
    let startedAt = Performance.now()
    let exited = ref(false)
    await scenario->Scenario.run(
      ~yamlSources=true,
      ~onExit=() => exited := true,
      async (~indexer, ~source as _) => {
        await Scenario.waitUntil(
          () => exited.contents,
          ~message="the chain to reach its end block",
          ~timeoutMs=1_200_000.,
        )
        await indexer->report(~seconds=startedAt->Performance.secondsSince)
      },
    )
  })

  Async.it_skipIf(mode !== Some("resume"))("resumes halfway through the history", async _ => {
    let hyperSync = (served->ServedEvmChain.servers).hyperSync
    hyperSync->MockHyperSyncServer.setHeight(height / 2)
    await resumeScenario->Scenario.run(
      ~yamlSources=true,
      async (~indexer, ~source as _) => {
        await indexer->waitForProgress(~block=height / 2, ~deadline=Date.now() +. 1_200_000.)
        await indexer.waitUntilIdle()
        let resumed = await indexer.restart()
        let startedAt = Performance.now()
        hyperSync->MockHyperSyncServer.setHeight(height)
        await resumed->waitForProgress(~block=height, ~deadline=Date.now() +. 1_200_000.)
        await resumed.waitUntilIdle()
        await resumed->report(~seconds=startedAt->Performance.secondsSince)
      },
    )
  })
})
