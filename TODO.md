# TODO

Follow-ups for internal changes — work a merged change left behind, written down
so it isn't rediscovered from scratch. Not a roadmap and not user-facing: user
requests belong in GitHub issues.

## Run an SVM source end to end against a mock server

`MockHyperSyncServer` speaks the EVM protocol only: its pages carry
`blocks`/`transactions`/`logs`, and `mock_hypersync_server.rs` encodes the
Cap'n Proto envelope EVM uses. Solana is a different wire format — a
length-framed `next_slot` + rollback-guard header followed by named Arrow IPC
tables, with `instruction_call` and `account_activity` among them — so no SVM
test crosses the napi boundary at all.

That gap is not theoretical. `transaction.allAccounts` shipped with its
three token states declared as `null` when napi was in fact omitting the
properties, and every test passed: the Rust tests stop at `Column::AllAccounts`,
before `ToNapiValue` runs, and the envio-tests case is `ts-expect` only, so
`fromUserApi` type-checks the handler without executing it. A Solana encoder for
the mock server would let one `createTestIndexer()` run over a SOL-only account
catch that class of bug.

## Expose `Account` on an instruction's own accounts

The spec's `Account` appears in three places: `transaction.allAccounts` (done),
`instruction.allAccounts`, and the named `instruction.accounts.<name>`. The
latter two are still `readonly string[]` — addresses without the lamport and
token sides. They need the same activity join keyed by the instruction's account
arguments rather than the transaction's key list.
