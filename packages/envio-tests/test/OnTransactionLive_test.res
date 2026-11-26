// Live test against eth.hypersync.xyz, driven through the user API: real
// config, real handlers, the real source filtering transactions on the
// server. The expected rows were read from a public Ethereum RPC, so they
// check the HyperSync path against an independent one.

let _apiToken =
  IndexerEnv.read().envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live onTransaction test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-live
chains:
  - id: 1
    start_block: ${OnTransactionLive.block->Int.toString}
    end_block: ${OnTransactionLive.block->Int.toString}
`,
  ~schema=OnTransactionLive.schema,
  ~handlers=OnTransactionLive.handlers,
  ~test=OnTransactionLive.test(~title="onTransaction over live HyperSync"),
)
