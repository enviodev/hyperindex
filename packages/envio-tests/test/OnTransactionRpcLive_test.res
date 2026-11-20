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

Vitest.it("reads the block in full once and a receipt per matched transaction", t => {
  let methods = proxy().queries->Array.map(query => {
    let call = query->(Utils.magic: JSON.t => {"method": string, "params": array<JSON.t>})
    switch (call["method"], call["params"]->Array.get(1)) {
    | ("eth_getBlockByNumber", Some(JSON.Boolean(true))) => "full block"
    | (method, _) => method
    }
  })
  let count = method => methods->Array.filter(called => called === method)->Array.length
  // The public node can fail a request, and the page is then read again whole,
  // so each read of the block is checked to bring its 15 receipts and nothing else.
  let blockReads = count("full block")
  t.expect((blockReads > 0, count("eth_getTransactionReceipt"), methods->Array.length)).toEqual((
    true,
    15 * blockReads,
    16 * blockReads,
  ))
})
