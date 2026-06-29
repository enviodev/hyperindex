// Pull-based metrics computed from live indexer state at scrape time, merged with
// the imperatively-updated prom-client default registry. Used because the address
// index is mutated in place (no single update site to fire a gauge from).

let indexingAddressesName = "envio_indexing_addresses"
let indexingAddressesHelp = "The number of addresses indexed on chain. Includes both static and dynamic addresses."

// Accumulate into one string rather than building a lines array to join: `++`
// compiles to JS `+=`, which V8 grows as a ConsString instead of recopying.
let renderGauge = (~name, ~help, ~samples: array<(string, int)>) => {
  let out = ref(`# HELP ${name} ${help}\n# TYPE ${name} gauge`)
  let prefix = `\n${name}{chainId="`
  for i in 0 to samples->Array.length - 1 {
    let (chainId, value) = samples->Array.getUnsafe(i)
    out := out.contents ++ prefix ++ chainId ++ `"} ` ++ value->Int.toString
  }
  out.contents
}

let collect = async (~state: option<IndexerState.t>) => {
  let base = await PromClient.defaultRegister->PromClient.metrics
  switch state {
  | None => base
  | Some(state) =>
    let samples = []
    state
    ->IndexerState.chainStates
    ->Utils.Dict.forEachWithKey((cs, chainId) => {
      samples->Array.push((chainId, cs->ChainState.numIndexingAddresses))
    })
    `${base}${renderGauge(~name=indexingAddressesName, ~help=indexingAddressesHelp, ~samples)}\n`
  }
}
