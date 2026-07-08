// Pull-based metrics computed from live indexer state at scrape time, merged with
// the imperatively-updated prom-client default registry. Used because the address
// index is mutated in place (no single update site to fire a gauge from).

let indexingAddressesName = "envio_indexing_addresses"
let indexingAddressesHelp = "The number of addresses indexed on chain. Includes both static and dynamic addresses."

// Render a gauge straight from the per-chain dict, one sample per key, without
// materialising an intermediate samples array. Accumulate into one string rather
// than building a lines array to join: `++` compiles to JS `+=`, which V8 grows
// as a ConsString instead of recopying.
let renderGauge = (~name, ~help, ~chains: dict<'a>, ~value: 'a => int) => {
  let out = ref(`# HELP ${name} ${help}\n# TYPE ${name} gauge`)
  let prefix = `\n${name}{chainId="`
  chains->Utils.Dict.forEachWithKey((chain, chainId) => {
    out := out.contents ++ prefix ++ chainId ++ `"} ` ++ value(chain)->Int.toString
  })
  out.contents
}

// Samples for envio_source_request_total/envio_source_request_seconds_total,
// aggregated per (source, chain, method) by SourceManager. The HELP/TYPE lines
// for both metric names are already emitted by prom-client's registry, via
// Prometheus.SourceRequestCount — still used directly by height-stream sources.
let renderSourceRequests = (~chainStates: dict<ChainState.t>) => {
  let out = ref("")
  chainStates->Utils.Dict.forEach(cs => {
    cs
    ->ChainState.sourceManager
    ->SourceManager.getRequestStatSamples
    ->Array.forEach(sample => {
      let labels = `{source="${sample.sourceName}",chainId="${sample.chainId->Int.toString}",method="${sample.method}"}`
      out :=
        out.contents ++
        `\nenvio_source_request_total${labels} ${sample.count->Int.toString}` ++
        `\nenvio_source_request_seconds_total${labels} ${sample.seconds->Float.toString}`
    })
  })
  out.contents
}

let collect = async (~state: option<IndexerState.t>) => {
  let base = await PromClient.defaultRegister->PromClient.metrics
  switch state {
  | None => base
  | Some(state) =>
    let chainStates = state->IndexerState.chainStates
    `${base}${renderGauge(
        ~name=indexingAddressesName,
        ~help=indexingAddressesHelp,
        ~chains=chainStates,
        ~value=cs => (cs->ChainState.toChainData).numAddresses,
      )}${renderSourceRequests(~chainStates)}\n`
  }
}
