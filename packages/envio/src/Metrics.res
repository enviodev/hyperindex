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

let sourceRequestTotalName = "envio_source_request_total"
let sourceRequestTotalHelp = "The number of requests made to data sources."
let sourceRequestSecondsTotalName = "envio_source_request_seconds_total"
let sourceRequestSecondsTotalHelp = "Cumulative time spent on data source requests."

// Hand-rolls both HELP/TYPE blocks and their samples straight from
// SourceManager's aggregates — fully our own state, no prom-client registry
// involved. A leading "\n" on each block since, unlike prom-client's own
// metrics() output, renderGauge's output right before this doesn't end in one.
// Skips a method's seconds line when it has no timing (e.g. heightSubscription,
// which only ever records a count), and skips both blocks entirely when there's
// nothing to report at all.
let renderSourceRequests = (~samples: array<SourceManager.requestStatSample>) => {
  if samples->Utils.Array.isEmpty {
    ""
  } else {
    let countOut = ref(
      `\n# HELP ${sourceRequestTotalName} ${sourceRequestTotalHelp}\n# TYPE ${sourceRequestTotalName} counter`,
    )
    let secondsOut = ref(
      `\n# HELP ${sourceRequestSecondsTotalName} ${sourceRequestSecondsTotalHelp}\n# TYPE ${sourceRequestSecondsTotalName} counter`,
    )
    samples->Array.forEach(sample => {
      let labels = `{source="${sample.sourceName}",chainId="${sample.chainId->Int.toString}",method="${sample.method}"}`
      countOut :=
        countOut.contents ++ `\n${sourceRequestTotalName}${labels} ${sample.count->Int.toString}`
      if sample.seconds !== 0. {
        secondsOut :=
          secondsOut.contents ++
          `\n${sourceRequestSecondsTotalName}${labels} ${sample.seconds->Float.toString}`
      }
    })
    countOut.contents ++ secondsOut.contents
  }
}

let collect = async (~state: option<IndexerState.t>) => {
  let base = await PromClient.defaultRegister->PromClient.metrics
  switch state {
  | None => base
  | Some(state) =>
    let chainStates = state->IndexerState.chainStates
    let sourceRequestSamples =
      chainStates
      ->Dict.valuesToArray
      ->Array.flatMap(cs => cs->ChainState.sourceManager->SourceManager.getRequestStatSamples)
    `${base}${renderGauge(
        ~name=indexingAddressesName,
        ~help=indexingAddressesHelp,
        ~chains=chainStates,
        ~value=cs => (cs->ChainState.toChainData).numAddresses,
      )}${renderSourceRequests(~samples=sourceRequestSamples)}\n`
  }
}
