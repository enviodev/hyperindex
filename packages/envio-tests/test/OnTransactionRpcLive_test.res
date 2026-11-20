// Live test against a public Ethereum RPC, through a recording proxy: the same
// handler and expected rows as the HyperSync live test, read through the RPC
// source. The block is read once in full, and a receipt only for the
// transactions the call filter matched, since the handler reads receipt
// fields.

let proxyPort = 18563
let proxy = RecordingProxy.serveDuringSuite(
  ~port=proxyPort,
  ~upstream="https://ethereum-rpc.publicnode.com",
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-rpc-live
chains:
  - id: 1
    rpc:
      url: http://127.0.0.1:${proxyPort->Int.toString}
      for: sync
    start_block: ${OnTransactionLive.block->Int.toString}
    end_block: ${OnTransactionLive.block->Int.toString}
`,
  ~schema=OnTransactionLive.schema,
  ~handlers=OnTransactionLive.handlers,
  ~test=OnTransactionLive.test(~title="onTransaction over a live RPC"),
)

Vitest.it("reads only the block in full and the receipts of the matched transactions", t => {
  // The public node can fail a request, which is then asked again, so the
  // requests are compared as a set: what was read, not how often.
  let requested = proxy().queries->Array.map(query => {
    let call = query->(Utils.magic: JSON.t => {"method": string, "params": array<JSON.t>})
    switch (call["method"], call["params"]) {
    | ("eth_getBlockByNumber", [JSON.String(number), JSON.Boolean(true)]) => `full block ${number}`
    | ("eth_getTransactionReceipt", [JSON.String(_)]) => "receipt"
    | (method, params) => `${method} ${params->JSON.stringifyAny->Option.getOr("")}`
    }
  })
  let distinctReceipts =
    proxy().queries
    ->Array.filterMap(query => {
      let call = query->(Utils.magic: JSON.t => {"method": string, "params": array<JSON.t>})
      switch (call["method"], call["params"]) {
      | ("eth_getTransactionReceipt", [JSON.String(hash)]) => Some(hash)
      | _ => None
      }
    })
    ->Utils.Set.fromArray
    ->Utils.Set.size
  t.expect((
    requested->Utils.Set.fromArray->Utils.Set.toArray->Array.toSorted(String.compare),
    distinctReceipts,
  )).toEqual(([`full block 0x${OnTransactionLive.block->Int.toString(~radix=16)}`, "receipt"], 15))
})
