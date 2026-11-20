open Vitest

// Eleven chains with no density signal. Each cold chain probes with one
// admission unit, a tenth of the 100-item pool, so with nine probes in flight
// exactly one unit is left for the tenth, and none for the eleventh.
let chainIds = Array.fromInitializer(~length=11, index => index + 1)

let chainYaml = id =>
  `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: fetch-state-admission
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainIds->Array.map(chainYaml)->Array.join("")}
`,
)

describe("Admission into the shared buffer pool", () => {
  scenario->Scenario.it(
    "admits a query with exactly one admission unit of the pool free, and none once in-flight probes fill it",
    ~sources=chainIds->Array.map((chain): Scenario.sourceMock => {chain: chain}),
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      chainIds->Array.forEach(chain => source(chain).resolveGetHeightOrThrow(100_000))
      await indexer.waitUntilIdle()
      t.expect(
        chainIds->Array.map(
          chain =>
            source(chain).pendingItemsQueries->Array.map(
              query =>
                indexer->QueryReservations.reservation(
                  ~chainId=chain,
                  ~partitionId=query.partitionId,
                  ~fromBlock=query.fromBlock,
                ),
            ),
        ),
      ).toEqual(chainIds->Array.map(chain => chain <= 10 ? [Some(10)] : []))
    },
  )
})
