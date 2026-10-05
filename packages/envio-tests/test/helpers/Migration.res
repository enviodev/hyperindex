type outcome =
  // The restart went ahead, and the database holds these chains afterwards.
  | Resumed(array<int>)
  // The restart was refused as an incompatible config change, naming these
  // config paths.
  | Refused(array<string>)
  // The restart was refused for another reason.
  | Failed(string)

let incompatibleHeader = "The following config changes are incompatible with the existing indexer data:"

let outcomeOfRefusal = message =>
  if message->String.startsWith(incompatibleHeader) {
    Refused(
      message
      ->String.split("\n")
      ->Array.filterMap(line =>
        line->String.startsWith("    - ") ? Some(line->String.slice(~start=6)) : None
      ),
    )
  } else {
    Failed(message)
  }

let storedChainIds = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "id": ChainId.t,
  }> = await sql->Sql.query(`SELECT "id" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`)
  rows->Array.map(row => row["id"]->ChainId.normalizeOrThrow->ChainId.toInt)
}

// `~chains` restarts as `envio start --chain` naming those chains; without it,
// as a plain `envio start`.
let it = (
  name,
  ~deployed: Scenario.t,
  ~edited: Scenario.t,
  ~chains: option<array<int>>=?,
  ~expected: outcome,
) => {
  let deployedChains = deployed.config.chainMap->ChainMap.keys->Array.map(ChainId.toInt)
  deployed->Scenario.it(
    name,
    ~sources=deployedChains->Array.map((chain): Scenario.sourceMock => {chain: chain}),
    ~supervised=false,
    async (~t, ~indexer, ~source) => {
      deployedChains->Array.forEach(chain => {
        let source = source(chain)
        source.resolveGetHeightOrThrow(100)
        source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      })
      await indexer.waitUntilReady()
      await indexer.waitUntilIdle()

      let config = edited.config->Scenario.withMockSources(
        ~sources=edited.config.chainMap
        ->ChainMap.keys
        ->Array.map(chainId => {
          let chain = chainId->ChainId.toInt
          (
            chain,
            deployedChains->Array.includes(chain)
              ? source(chain)
              : MockSource.make(Scenario.defaultMethods, ~chainId=chain),
          )
        }),
      )
      let outcome = switch await indexer.restart(
        ~config,
        ~chains=?chains->Option.map(chains => chains->Array.map(ChainId.fromInt)),
        (),
      ) {
      | restarted => Resumed(await storedChainIds(restarted))
      | exception JsExn(e) => outcomeOfRefusal(e->JsExn.message->Option.getOr(""))
      | exception Persistence.StorageError({message}) => outcomeOfRefusal(message)
      }

      t.expect(outcome).toEqual(expected)
    },
  )
}
