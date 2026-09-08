# svm_balance_ledger

Every SPL token account's balance history on Solana, reconstructed without
reading account state even once.

## The idea

An indexer that wants token balances normally reaches for account state:
`getTokenAccountBalance` for one account, `getProgramAccounts` for a mint's
holders. Both answer for the current slot only. The historical question — *what
did this account hold at slot N* — has no RPC answer at all without an archive
node replaying the account.

Solana already reports the answer, on every transaction. A transaction's
metadata carries the pre- and post-transaction token amount of every account it
touched, and HyperSync delivers those alongside each matched instruction as
`transaction.accountActivities`. So the balance history is derivable from the
transaction stream, with no account reads and no snapshots:

```
balance(account, slot) = postAmount of the last change at or before that slot
```

The indexer decodes nothing. It declares no `args` and no `accounts` — the
discriminators in `config.yaml` exist only to select which transactions to
receive.

## Why it is auditable

Deriving state from a stream is only sound if the stream is complete. This one
is, and proves it rather than asserting it.

An SPL token account's `amount` moves in exactly eight ways: `transfer`,
`transferChecked`, `mintTo`, `mintToChecked`, `burn`, `burnChecked`,
`closeAccount`, and `syncNative` — plus, on Token-2022, the transfer-fee and
confidential-transfer extension instructions. `config.yaml` matches all of them,
across both token programs, at any CPI depth. That is the complete set, so no
balance change can happen outside it.

Every `BalanceChange` row carries `expectedPre`: the balance this ledger carried
forward from that account's previous change. The chain also reports `preAmount`
for the same moment. If the two disagree, a transaction that moved the balance
was missed — the ledger records it as a gap instead of absorbing it:

```sql
SELECT * FROM v_ledger_gap;   -- empty is the claim
```

`src/indexer.test.ts` runs that check over a live slot window and fails if any
row is discontinuous. Thirty slots reconstruct 22,629 balance changes across
10,083 token accounts and 741 mints, of which 1,954 accounts are seen more than
once — the busiest 191 times — with zero gaps, in under ten seconds. The
reconstruction is checked against the chain's own numbers on every single
change.

A second invariant falls out for free. Summing every account delta per
(transaction, mint) gives `TxMintFlow.sumDelta`, which must be zero for a
transaction whose token instructions were only classic SPL Token transfers —
tokens moved between accounts, none were created. What survives the sum is
minting, burning, and wrapped-SOL syncing, so `v_mint_supply_change`
reconstructs each mint's supply change without ever reading a mint account.

Token-2022 transfers are excluded from that invariant on purpose. A Token-2022
mint can carry a transfer fee, and the withheld part lands in the destination's
withheld field rather than its `amount` — the test window contains a mint with a
99.99% fee, whose recipient shows a delta four orders of magnitude smaller than
the sender's. The two sides of that transfer do not sum to zero, and no bug is
involved.

## Where the data lives

The ledger is append-only and always read as an aggregate over a slot range, so
`BalanceChange`, `TxMintFlow` and `TxTokenInstruction` are stored in ClickHouse
alone. `TokenAccount` — the one mutable entity, a running balance updated in
place — is in Postgres, because the handler reads it back to check continuity and
ClickHouse storage is write-only from handlers; it is mirrored to ClickHouse for
the UI.

`BalanceChange` declares its ClickHouse sort key as `(account, slot, txIndex)`,
which is the point-in-time query itself: finding a balance at a slot is a
primary-key range scan rather than a search.

The handler does no aggregation. It writes flat, idempotent rows and leaves every
fold to the query layer — including whether a transaction conserved its tokens,
which `v_conservation_check` derives by joining `TxMintFlow` against the
instructions the transaction carried.

## The query layer

`sql/clickhouse.sql` holds it, as parameterised views:

| View | Answers |
| --- | --- |
| `balance_at(account, at_slot)` | What did this account hold at that slot? |
| `holders_at(mint, at_slot)` | Who held this mint then, largest first? |
| `account_history(account)` | The whole timeline for one account. |
| `v_ledger_gap` | Which changes the ledger could not account for. Empty is the claim. |
| `v_conservation_check` | Transfer-only transactions, which must sum to zero. |
| `v_mint_supply_change` | Net supply movement per mint, with no mint account read. |
| `v_ledger_summary` | Headline counts. |

A GraphQL `BigInt` is stored as a ClickHouse `String`, which is why the views cast
before summing or ordering — lexicographic order on a decimal string is not
numeric order.

## The UI

`ui/index.html` is a single file with no build step and no dependencies. It talks
to ClickHouse's HTTP interface straight from the browser, and every panel shows
the SQL it ran. Values are bound as ClickHouse query parameters, so a pasted
address never reaches the query text.

- **Time machine** — holders of a mint as of a slot, with the slot on a slider.
  Drag it back and the balances are the ones that stood at that moment. Click a
  bar to open that account.
- **Account ledger** — one account's balance as a step function, because a
  balance holds between changes.
- **Audit** — the gap and conservation checks, run live.
- **Supply movement** — net supply change per mint, derived from deltas alone.

## Run it

```bash
pnpm install
pnpm codegen
pnpm test          # live E2E against solana.hypersync.xyz over a pinned window
```

To index for real and open the UI:

```bash
pnpm dev                        # brings up Postgres + ClickHouse, then indexes
./apply-views.sh                # creates the views in ClickHouse
pnpm ui                         # serves ui/ at http://localhost:5173
```

`apply-views.sh` reads the same `ENVIO_CLICKHOUSE_*` variables the indexer does,
and has to be re-run after any `pnpm codegen` that changes the entity tables.

The browser needs ClickHouse to send CORS headers, which the UI requests per
query with `add_http_cors_header=1`; nothing has to be configured server-side.

## Scope

`config.yaml` is the only config. `START_SLOT` and `END_SLOT` override the window
through the `${VAR:-default}` interpolation the config loader already supports, so
a pinned window needs an environment variable rather than a second file — that is
how the test fixes its 30 slots:

```bash
START_SLOT=420650000 END_SLOT=420650029 pnpm start
```

An unset `END_SLOT` leaves `end_block` null, which indexes to the chain head.

The default window is deliberately short. Token movement is the highest-volume
traffic on Solana and this config matches all of it — widen it only against a
HyperSync endpoint you control.

Balances are reconstructed for accounts the window actually saw. An account's
first change in the window opens its ledger at whatever `preAmount` the chain
reported there, rather than at zero, so `openingBalance` is a window boundary and
not a claim about the account's history before it.
