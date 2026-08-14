# TODO

Follow-ups for internal changes — work a merged change left behind, written down
so it isn't rediscovered from scratch. Not a roadmap and not user-facing: user
requests belong in GitHub issues.

## Cover field selection at the indexer-loop level

`HyperSyncSourceContract_test` now covers a single fetch: the query the source
sends, and the fields each registration's item carries after
`ChainState.materializePageItems`. What it doesn't cover is the loop around that
— partition splitting, reorgs, batching, the chain stores accumulating across
pages. That belongs on `MockIndexer` (`scenarios/test_codegen`), which runs the
real loop, and can now drive a real HyperSync source against the addon's
`MockHyperSyncServer` instead of mocking `Source` — its ReScript binding lives
in `packages/envio-tests/test/helpers` and would have to be shared.

## HyperSync paths the mock server still can't reach

`MockHyperSyncServer` speaks the EVM JSON query format only. Left uncovered:

- **The production request format.** `ENVIO_HYPERSYNC_CLIENT_SERIALIZATION_FORMAT`
  defaults to Cap'n Proto with query caching, so every test that points a source
  at the mock has to opt into `Json` — the format indexers actually run on, and
  its cached-query round trip (send query id, server may answer `notCached`),
  are exercised by nothing.
- **SVM and Fuel.** Both have their own wire format (`/query/arrow` with a custom
  framing for SVM). `SvmHyperSyncSource` shares its block-hash plumbing with the
  EVM one — including the detached-method bug fixed alongside this test — and
  nothing covers it.
- **A fork across block-hash pages.** `paginate_block_hashes` re-requests the
  last block of the previous page so a fork switch surfaces as a hash collision
  in `appendPage`. The pagination test covers the happy seam; the colliding one
  is only covered by Rust unit tests with canned pages.
