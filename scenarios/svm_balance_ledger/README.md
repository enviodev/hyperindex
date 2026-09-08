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

## Run it

```bash
pnpm install
pnpm codegen
pnpm test          # live E2E against solana.hypersync.xyz, pinned slot window
```

To index for real:

```bash
pnpm docker-up
pnpm dev
psql -h localhost -p 5433 -U postgres -d envio-dev -f sql/views.sql
```

Then the time-machine queries:

```sql
-- what this account held at slot 422,300,500
SELECT balance_at('4ct7br2vTPzfdmY3S5HLtTxcGSBfn6pnw98hsS6v359A', 422300500);

-- every USDC holder in the window, as of that slot, largest first
SELECT * FROM holders_at('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 422300500)
LIMIT 20;
```

`sql/views.sql` has to be re-applied after each `pnpm codegen`, which recreates
the entity tables and drops the views that depend on them.

## Scope

The slot window in `config.yaml` is deliberately short. Token movement is the
highest-volume traffic on Solana and this config matches all of it — widen the
window only against a HyperSync endpoint you control.

Balances are reconstructed for accounts the window actually saw. An account's
first change in the window opens its ledger at whatever `preAmount` the chain
reported there, rather than at zero, so `openingBalance` is a window boundary and
not a claim about the account's history before it.
