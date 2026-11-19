open Vitest

let config = (~url="http://localhost:8545", ~limit=?) =>
  TestConfig.fromUserApi(
    `
name: rpc-concurrency
chains:
  - id: 1
    start_block: 0
    rpc:
      url: ${url}
      for: sync
      ${limit->Option.map(n => "max_concurrent_requests: " ++ n->Int.toString)->Option.getOr("")}
`,
  )

let chain = (config: Config.t) => config.chainMap->ChainMap.values->Array.getUnsafe(0)

describe("RPC concurrency configuration", () => {
  it("Keeps a configured limit through the public config and runtime parsing", t => {
    switch config(~limit=2)->chain {
    | {sourceConfig: EvmSourceConfig({rpcs})} =>
      t.expect(rpcs->Array.map(rpc => rpc.maxConcurrentRequests)).toEqual([Some(2)])
    | _ => t.expect("an EVM source").toEqual("missing")
    }
  })

  it("Leaves the limit unset when omitted so the native default applies", t => {
    switch config()->chain {
    | {sourceConfig: EvmSourceConfig({rpcs})} =>
      t.expect(rpcs->Array.map(rpc => rpc.maxConcurrentRequests)).toEqual([None])
    | _ => t.expect("an EVM source").toEqual("missing")
    }
  })

  [1, 2]->Array.forEach(limit => {
    Async.itWithOptions(
      `Limits requests made by a source built from YAML to ${limit->Int.toString}`,
      {retry: 3},
      async t => {
        let inFlight = ref(0)
        let peak = ref(0)
        let heights = await MockRpcServer.withScenario(
          ~name="configured source request concurrency",
          ~calls=[
            MockRpcServer.expectCall(
              ~method="eth_blockNumber",
              ~times=6,
              ~reply=Dynamic(
                _ => {
                  inFlight := inFlight.contents + 1
                  peak := Pervasives.max(peak.contents, inFlight.contents)
                  Delayed({
                    millis: 150,
                    reply: Dynamic(
                      _ => {
                        inFlight := inFlight.contents - 1
                        RpcResult(JSON.String("0x10"))
                      },
                    ),
                  })
                },
              ),
            ),
          ],
          async mock => {
            let sources = ChainSources.make(
              ~chainConfig=config(~url=mock.url, ~limit)->chain,
              ~onEventRegistrations=[],
              ~addressStore=TestAddresses.makeStore(),
              ~lowercaseAddresses=false,
              ~blockStore=BlockStore.make(~ecosystem=Evm),
              ~transactionStore=TransactionStore.make(~ecosystem=Evm),
              ~logger=Logger.makeInMemory(),
              ~maxAddressesPerRequest=Env.maxAddrInPartition,
            )
            let source = sources->Array.getUnsafe(0)
            await [0, 1, 2, 3, 4, 5]
            ->Array.map(async _ => (await source.getHeightOrThrow()).height)
            ->Promise.all
          },
        )
        t.expect(heights).toEqual([16, 16, 16, 16, 16, 16])
        t.expect(peak.contents).toEqual(limit)
        t.expect(inFlight.contents).toEqual(0)
      },
    )
  })
})
