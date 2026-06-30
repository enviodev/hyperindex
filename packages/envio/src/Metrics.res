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

let collect = async (~state: option<IndexerState.t>) => {
  let base = await PromClient.defaultRegister->PromClient.metrics
  switch state {
  | None => base
  | Some(state) =>
    `${base}${renderGauge(
        ~name=indexingAddressesName,
        ~help=indexingAddressesHelp,
        ~chains=state->IndexerState.chainStates,
        ~value=cs => (cs->ChainState.toChainData).numAddresses,
      )}\n`
  }
}
