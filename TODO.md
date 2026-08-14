# TODO

Follow-ups for internal changes — work a merged change left behind, written down
so it isn't rediscovered from scratch. Not a roadmap and not user-facing: user
requests belong in GitHub issues.

## Cover field selection at the indexer-loop level

Every inline-`fields` test stops at the registration or the HyperSync query
input. Nothing confirms a handler that selected `{transaction: ["to"]}` actually
receives `to`, or that a sibling registration on the same event receives its own
narrower set — the per-(block, txIndex) materialisation between the two is
untested. Belongs on `MockIndexer` (`scenarios/test_codegen`), which runs the
real loop with `Source` and `Storage` mocked.

## Mock HyperSync server for an end-to-end source test

The HyperSync source is only ever exercised against the real service, so its
tests can't run in CI without network and can't pin a response. A mock server
speaking the HyperSync query/response protocol would give the source a real
end-to-end test, and would validate that field selection is honoured all the way
from the query it sends to the fields a handler reads.
