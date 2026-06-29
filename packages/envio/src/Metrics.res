// Pull-based metrics computed from live indexer state at scrape time, merged with
// the imperatively-updated prom-client default registry. Used because the address
// index is mutated in place (no single update site to fire a gauge from).

let indexingAddressesName = "envio_indexing_addresses"
let indexingAddressesHelp = "The number of addresses indexed on chain. Includes both static and dynamic addresses."

// Single-pass exposition builder: indexed `for` loop, string `+=` (V8 grows these
// as ConsStrings — no O(n²) copying), direct tuple-slot access, and the `int`
// value coerced by `+` instead of an Int.toString round-trip. Avoids the
// intermediate `lines` array, the per-line closure, and the join an idiomatic
// ReScript version would allocate.
let renderGauge: (
  ~name: string,
  ~help: string,
  ~samples: array<(string, int)>,
) => string = %raw(`function (name, help, samples) {
  var out = "# HELP " + name + " " + help + "\n# TYPE " + name + " gauge";
  var prefix = "\n" + name + '{chainId="';
  for (var i = 0, n = samples.length; i < n; i++) {
    var s = samples[i];
    out += prefix + s[0] + '"} ' + s[1];
  }
  return out;
}`)

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
