# SVM payload types — decisions

Amends §5 (Payloads) and §7 (Field selection) of the HyperIndex SVM API spec.
Records what we settled and the measurements behind it. Breaking changes are
accepted; SVM config still sits under `experimental:`.

## Measured against the live endpoint

Sampled near head on `solana.hypersync.xyz`, SPL Token instructions, after the
endpoint moved to the merged `account_activity` table.

| Observation | Result |
| --- | --- |
| Account keys with an activity row | 533 / 1442 |
| Rows carrying a native side | 385 / 841 |
| Rows carrying a native side where `pre == post` | 0 / 385 |
| Rows with a literal `0` balance | 27 pre, 13 post |
| Fee-payer rows missing a native side | 0 / 121 |
| `account_index`, `is_signer`, `is_writable`, `token_state` | 100% of rows |
| `token_decimals`, resolved `owner` | 100% of token rows |
| Instructions passing one account more than once | 140 / 1187 |
| Instruction arguments absent from `account_keys` | 386 / 3140 |
| Activity rows for accounts absent from `account_keys` | 134 / 1204 |
| `account_index_arguments` served | 1187 / 1187 |

Three conclusions drive everything below.

**An activity row exists only where something moved.** Not per account key. A
left join of the key list onto activity manufactures nulls for 63% of entries,
which is what the first `allAccounts` attempt did.

**A missing native side means "lamports unchanged", not "unknown" and not
"zero".** Zero is representable, no emitted native side is ever unchanged, and
the fee payer — who always pays — always has one. Nothing is lost; the source
elides two `u64`s on rows that exist for a token reason.

**An instruction's account arguments are not a key table.** They repeat (12% of
instructions pass the same account twice), they are ordered by the program
rather than the protocol, and 12% of them are not in `account_keys` at all
because that column carries only the message's static keys.

## Settled

| Decision | Call |
| --- | --- |
| Named-account type | `InstructionAccount`. Field `instruction.accounts.user`. `accountArguments` stays `string[]`. |
| Activity type | `AccountActivity` / `accountActivities` / `.activity` — not `Change` |
| Presence | Undefinable (`T \| undefined`), never `null`, never `?:`. Selected + absent = `undefined`. Unselected is `FieldNotSelected`. |
| Indexes | `instructionAccountIndex` on `InstructionAccount`; `transactionAccountIndex` on `AccountActivity`. Never both as `accountIndex`. |
| `params` | Gone. `instruction.args`, `instruction.accounts`. No `extraAccounts`, no `params.name` (`instructionName` is the registration). |
| Remaining accounts | No `remainingAccounts`. Escape hatch is `accountArguments`. |
| `accountKeys` | Resolved list: static ++ ALT writable ++ ALT readonly. `accountKeys[activity.transactionAccountIndex] === activity.address`. Static-only, if ever needed, is a separate field. |
| Field selection | Handler `fields` only. No `field_selection` in SVM `config.yaml`. No default column sets. Nested selection implies the parent array (`accountActivity: [...]` ⇒ `transaction.accountActivities`; `log: [...]` ⇒ `instruction.logs`). |
| Discriminator payload | One `instruction.discriminator` (`0x`-hex of the matched prefix). Drop `d1`/`d2`/`d4`/`d8` from the handler payload. |
| `tokenChanges` | Do not add. |
| Identity | `instruction.accounts.<name>.activity` and `transaction.accountActivities[i]` are the same object when a row exists. |
| Native side | Nested `lamports: { pre, post } \| undefined`. `undefined` = unchanged. `pre`/`post` are required `bigint` when `lamports` is present (always a pair). |

## Types

```ts
type AccountActivity = {
  address: string
  transactionAccountIndex: number
  isSigner: boolean
  isWritable: boolean
  lamports: { pre: bigint; post: bigint } | undefined
  token: {
    mint: string
    owner: string
    decimals: number
    preAmount: bigint | undefined
    postAmount: bigint | undefined
  } | undefined
}

type InstructionAccount = {
  address: string
  accountName: string
  instructionAccountIndex: number
  activity: AccountActivity | undefined
}

type Log = {
  kind: "invoke" | "success" | "failed" | "consumed" | "log" | "data" | "other"
  message: string
}
```

`AccountActivity` is a row: it exists because something moved, so everything a
row always carries is required once selected (`isSigner`, `isWritable`,
`transactionAccountIndex`, `address`). `InstructionAccount` is a named IDL
slot: the address is always known, `activity` is `undefined` when this account
did not move.

`isSigner` / `isWritable` do not live on `InstructionAccount`. Reading them
requires narrowing `activity`. That is the whole point of the wrapper — today's
`SvmAccount.isSigner: boolean | null` is the lie (null means "no row", not
"not a signer").

`accountName` and `instructionAccountIndex` come from the IDL. They are
instruction-scoped: the same pubkey is `user` in one ix and `authority` in
another. Do not put them on `AccountActivity`. `transactionAccountIndex` is
the resolved key-list position and belongs only on the row.

IDL `signer` / `writable` / `optional` flags stay off the payload. Those are
schema requirements; the activity row's `isSigner` / `isWritable` are message
facts, and they only exist when a row exists.

`lamports` and `token` are the two **sides** of the row, not moves — the row
is already the activity. `lamports` is the native pair; `undefined` means
unchanged, and when present both `pre` and `post` are `bigint` (measured:
never one-sided, never `pre == post`). `token` is the token side: identity
(`mint` / `owner` / `decimals`) plus amounts. Amounts stay `preAmount` /
`postAmount` (SPL's word) and may be `undefined` on a defined `token`
(opened / closed / opened-and-closed). `user.activity.token.mint` reads;
`tokenMove` would not.

`InstructionAccount` rather than `Account`: it is a slot on this instruction,
not the on-chain account and not a user GraphQL entity. The field stays
`accounts.user` (Anchor-shaped). `accountArguments` stays `string[]` so the
positional hatch does not grow a richer API than the named path.

## Presence

Three representations, never mixed:

| State | Type | Meaning |
| --- | --- | --- |
| Unselected | `FieldNotSelected` | Compile error. You did not ask for this field. |
| Selected, absent | `T \| undefined` | Documented semantic absence (table below). |
| Selected, present | `T` | The value. |

Undefinable (`activity: AccountActivity | undefined`), not optional
(`activity?: AccountActivity`) and not nullable (`activity: AccountActivity | null`).
`?:` means “this field might not be part of the shape,” which is
`FieldNotSelected`. `| undefined` means “you selected it; the value may be
absent.” Same convention as EVM (`from: Address | undefined`).

| `undefined` | Meaning | Only valid when |
| --- | --- | --- |
| `InstructionAccount.activity` | No activity row — this account did not move | `accountActivity` fields were selected |
| `lamports` | Lamports unchanged (token-only row) | at least one `lamports.*` field was selected |
| `token` | Not a token account | at least one `token.*` field was selected |
| `token.preAmount` | Token account opened during this transaction | `preAmount` was selected |
| `token.postAmount` | Token account closed during this transaction | `postAmount` was selected |
| `instruction.args` | Borsh decode failed | `args` was selected |

If you did not select `token.*`, `token` is `FieldNotSelected` — you did not
fetch `mint`, so you do not know “not a token account.” Same for `lamports`
and `isSigner`: unselected is a compile error, not `false` / `undefined`.

Nesting `lamports` encodes the pair invariant the flat `preLamports` /
`postLamports` could only document. Selection uses the same dotted paths as
token: `"lamports.post"`. Flat names were rejected so `undefined` on one side
could not mean “unchanged” while the other was a value.

Never emit `null`. Drop `#[napi(object, use_nullable = true)]`. napi's default
omits unset fields at runtime; that is fine — read `user.activity`, never
`'activity' in user`. JSON.stringify drops `undefined` too.

Row identity that the join already paid for is always on the object:
`AccountActivity.address`, `InstructionAccount.address` / `accountName`. That
is the EVM `block.number` exception. Everything else is listed or it does not
exist.

`block.slot` is always included (the item's key). `programName` /
`instructionName` are always included (the registration).

Once selected, a field a row always carries stays required (`isSigner`,
`token.mint`, `lamports.pre` / `lamports.post` when `lamports` is present).
`| undefined` is only for documented absences, not “we might have forgotten
to set it.”

## Payload fields

```ts
transaction.accountKeys         // string[]              resolved key table
transaction.accountActivities   // AccountActivity[]     implied by fields.accountActivity

instruction.accounts.user       // InstructionAccount    IDL-named
instruction.accountArguments    // string[]              every account passed, in program order
instruction.args                // decoded args | undefined  decode failed
instruction.discriminator       // string                0x-hex of the matched prefix
instruction.logs                // Log[]                 implied by fields.log
```

**`accountKeys` vs `accountArguments` are deliberately different names** because
they are different kinds of collection: a unique, protocol-ordered key table
versus a possibly-repeating, program-ordered argument sequence.

`accountArguments` pairs with `args`: an instruction takes account arguments
and data arguments (`Instruction { program_id, accounts, data }`). It matches
the wire column.

Named accounts do not depend on Borsh decode. `instruction.accounts.user.address`
is IDL names zipped onto `account_arguments`. `instruction.args` is the only
decode product, and is `undefined` when decode fails (IDL drift). That is
runtime absence, not field selection.

Raw instructions have no IDL and therefore no `accounts` and no `args`; they
carry `accountArguments` and `discriminator` alone.

Selecting named accounts does not fetch `account_activity`. `.activity` is on
the type only when `accountActivity` fields are selected; otherwise it is
`FieldNotSelected`.

## Object identity

`transaction.accountActivities[i]` and `instruction.accounts.<name>.activity`
are the **same object** for the same account. Payloads sharing a `(slot,
transactionIndex)` already share one transaction object via `groupBatchItems` /
`applyTransactionGroups`; activity objects are built once per transaction and
referenced. Identity comparison works, and a transaction with many instructions
holds one copy.

`InstructionAccount` objects are per instruction slot, not shared.

## Logs

Wire `LogField`: `slot`, `transaction_index`, `instruction_address`,
`program_id`, `kind`, `message`.

Payload exposes **`kind` and `message`**. The rest are join keys used to attach
the log to this instruction (exact `instruction_address` match) and are not on
the handler object. Unscoped logs (`instruction_address` missing) are dropped.
`program_id` would duplicate `instruction.programId` after that scoping.

`kind` is the Solana log line class (prefix stripped from `message`):

| kind | Source line |
| --- | --- |
| `invoke` | `Program <id> invoke [<depth>]` |
| `success` | `Program <id> success` |
| `failed` | `Program <id> failed: <err>` |
| `consumed` | `Program <id> consumed <n> of <m> compute units` |
| `log` | `Program log: <msg>` |
| `data` | `Program data: <base64>` |
| `other` | anything else, kept verbatim (e.g. `Program return: …`) |

SQD-ingested ranges and default RPC ranges only persist `log` / `data` /
`other`. Framing `invoke` / `success` / `failed` / `consumed` are dropped for
cross-source parity. Do not assume every invocation has an `invoke` row.

No `logs: true` default. List the log columns; that implies `instruction.logs`:

```ts
fields: { log: ["kind", "message"] }
```

Selecting a subset is allowed (`log: ["kind"]`). There is no log-level
`programId` on the payload unless we later add it as an explicit field.

## Removed

| Removed | Reason |
| --- | --- |
| `params` (and `SvmInstructionParams`) | Bag around args + accounts + name + extra. Accounts moved; name duplicated `instructionName`; extra is `accountArguments`. |
| `transaction.tokenBalances` | `accountActivities.filter(a => a.token)` |
| `token_balance_fields` / `field_selection` in YAML | Handler `fields` only |
| `transaction.allAccounts` | Replaced by `accountKeys` + `accountActivities` |
| `remainingAccounts` / `params.extraAccounts` | Derivable from `accountArguments` beyond the schema's count; a named list would compete with `accounts.<name>` |
| `d1` / `d2` / `d4` / `d8` on the payload | One `discriminator` (matched prefix). Wire columns still used for query matching. |
| The `Account` left join | No key-list join; `accountActivities` orders by `transactionAccountIndex` |
| `transaction.tokenChanges` | Same objects, second name. Add only if handlers ask twice. |
| `null` / `?:` for semantic absence | `T \| undefined` once selected. `FieldNotSelected` if not. napi omits at runtime; do not emit `null`. |
| `transaction: ["accountActivities"]` | Implied by `fields.accountActivity`. |
| `logs: true` | Implied by `fields.log`. No default column set. |
| Flat `preLamports` / `postLamports` | Nested `lamports: { pre, post } \| undefined` so the pair is in the type. |

Dropping the join also deletes the lookup-table special case: no `BTreeMap` of
unjoined rows, no address-order tail, and no forced `account_keys` fetch.

## Field selection

SVM has **no** `field_selection` in `config.yaml`. Selection lives on the
handler, next to the code that reads it, and is the source of truth for both
the query and the types (same as EVM inline `fields`, without a YAML fallback).

```ts
indexer.onInstruction(
  {
    program: "Jupiter",
    instruction: "route",
    fields: {
      instruction: ["args", "accounts", "accountArguments", "discriminator"],
      transaction: ["signature", "accountKeys"],
      accountActivity: ["transactionAccountIndex", "lamports.post", "token.mint"],
      block: ["hash", "time"],
      log: ["kind", "message"],
    },
  },
  async ({ instruction }) => {
    const mint = instruction.accounts.destinationMint.address
    const inAmount = instruction.args.inAmount
    const t = instruction.accounts.userSourceTokenAccount.activity?.token
  },
)
```

Rules:

- Nested selection implies the parent array. `accountActivity: ["lamports.post"]`
  is enough to put `transaction.accountActivities` on the payload. Do not also
  list `accountActivities` under `transaction`. Same for `log` ⇒
  `instruction.logs`. An empty nested list is a config error.
- No implied column set inside the nested type. You get exactly the fields
  listed.
- Dotted paths for nested sides: `"lamports.post"`, `"token.mint"`. If no
  `token.*` is listed, `token` is `FieldNotSelected`. Same for `lamports`.
- `accountKeys` and `accountArguments` take no sub-selection (`string[]`).
- `args` is all-or-nothing (`instruction: ["args"]`). Per-field arg selection
  copies a HyperSync cost model onto local Borsh decode.
- YAML still declares discriminator, IDL `accounts` / `args`, `account_filters`,
  `is_inner`. That is schema and filtering, not payload selection.

This is what makes the split pay: `accountActivity` fields need no transaction
column, so a token-flow indexer stops paying for the key table. The old
`allAccounts` always billed for both. Named addresses do not bill activity.

## Handler reads

```ts
// named address (once `accounts` is selected — no activity fetch)
const mint = instruction.accounts.destinationMint.address

// named token flow
const t = instruction.accounts.userSourceTokenAccount.activity?.token
if (t?.preAmount !== undefined && t.postAmount !== undefined) {
  const delta = t.postAmount - t.preAmount
}

// named SOL flow — undefined lamports is a zero delta, not a zero balance
const sol = instruction.accounts.user.activity?.lamports
const solDelta = sol === undefined ? 0n : sol.post - sol.pre

// tx-level movements, no key table billed
for (const a of instruction.transaction.accountActivities) {
  if (a.token) { /* … */ }
}

// remaining / raw: strings, join yourself
const addr = instruction.accountArguments[8]
const row = instruction.transaction.accountActivities.find(a => a.address === addr)
```

`lamports === undefined` is a correct **delta** of 0 and a wrong **snapshot**
(you cannot recover the balance). Document that; do not add `lamportsDelta`
on the row.

## Open

### Implementation only

`token_state` is served and authoritative; the implementation currently infers
the token side from `mint` presence. Internal change, no payload impact.

`token.owner` is `post ?? pre`. The wire splits `pre_owner` / `post_owner`
(`SetAuthority(AccountOwner)`). Single `owner` for v1; do not pretend the
split was measured as "never differs."

## Asks for the HyperSync team

Everything §12 previously asked for is now served and populated, except:

- **`a6`…`a9` in the napi client.** Ours to fix: upstream filters through `a9`,
  `types.rs` stops at `a5`. Blocks named-account filters past position 5.
- **Populate `pre_balance`/`post_balance` on every row** — low priority. Only
  balance-snapshot use cases need it; flow analysis reads an absent native side
  as a zero delta, which is complete. Costs two `u64`s on 54% of rows.
