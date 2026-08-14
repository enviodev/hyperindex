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
