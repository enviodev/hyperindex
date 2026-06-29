// Pull-based metrics computed from live indexer state at scrape time, merged with
// the imperatively-updated prom-client default registry. Used because the address
// index is mutated in place (no single update site to fire a gauge from).

let indexingAddressesName = "envio_indexing_addresses"
let indexingAddressesHelp = "The number of addresses indexed on chain. Includes both static and dynamic addresses."

let renderGauge = (~name, ~help, ~samples: array<(string, int)>) => {
  let lines = [`# HELP ${name} ${help}`, `# TYPE ${name} gauge`]
  samples->Array.forEach(((chainId, value)) => {
    lines->Array.push(`${name}{chainId="${chainId}"} ${value->Int.toString}`)
  })
  lines->Array.joinUnsafe("\n")
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
      samples->Array.push((chainId, cs->ChainState.indexingAddresses->Utils.Dict.size))
    })
    `${base}${renderGauge(~name=indexingAddressesName, ~help=indexingAddressesHelp, ~samples)}\n`
  }
}
