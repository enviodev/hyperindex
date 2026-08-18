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

## Types

```ts
type AccountChange = {
  address: string
  accountIndex: number
  isSigner: boolean
  isWritable: boolean
  preLamports: bigint | null
  postLamports: bigint | null
  token: {
    mint: string
    owner: string
    decimals: number
    preAmount: bigint | null
    postAmount: bigint | null
  } | null
}

type Account = {
  address: string
  change: AccountChange | null
}
```

`AccountChange` is a row: it exists because something moved, so everything a row
always carries is non-null. `Account` is a slot in an instruction's argument
list: the address is always known, the change may not exist.

The wrapper is the same move §5 already makes for `token` — one null check gates
a correlated group. Without it, `AccountChange.isSigner` would have to be typed
nullable purely to accommodate the named-account case, despite being present on
every row. The cost is one `?.` on the common read.

## Nullability

Every `null` means exactly one thing, and they are all distinguishable:

| Null | Meaning |
| --- | --- |
| `Account.change` | No activity row — this account did not move |
| `preLamports` / `postLamports` | Lamports unchanged by this transaction (always absent as a pair) |
| `token` | Not a token account |
| `token.preAmount` | Token account opened during this transaction |
| `token.postAmount` | Token account closed during this transaction |

Lamports stay **flat**, not nested under a `native` object. Nesting was proposed
to model the omission before we knew it meant "unchanged"; a documented null
carries that meaning without a level of narrowing, and keeps
`accountChange: ["postLamports"]` expressible as §5 intended.

Nullable fields must be emitted as `null`, never omitted. In Rust that means
`#[napi(object, use_nullable = true)]` — the default guards each optional
field's `set`, so the property goes missing and a `=== null` check never fires.

## Payload fields

```ts
transaction.accountKeys      // string[]          the message's key table
transaction.accountChanges   // AccountChange[]   accounts that moved, by accountIndex

instruction.accounts.user    // Account           IDL-named
instruction.accountArguments // string[]          every account passed, in program order
```

**`accountKeys` vs `accountArguments` are deliberately different names** because
they are different kinds of collection: a unique, protocol-ordered key table
versus a possibly-repeating, program-ordered argument sequence. Uniform naming
would imply an interchangeability the data contradicts.

`accountArguments` also pairs with `args`: an instruction takes account
arguments and data arguments, which is the on-chain model
(`Instruction { program_id, accounts, data }`). It matches the wire column name.

**Addresses, not indexes**, on the instruction. An address is already a unique
key within a transaction, so an index carries no extra information; it is only
compactness, and it fails self-containment (`accounts[0] === 3` needs
`accountKeys` selected to mean anything). `accountIndexes` stays available as a
purely additive field if profiling ever asks for it — the wire serves it on
every instruction.

Raw instructions have no IDL and therefore no `accounts`; they carry
`accountArguments` alone. This removes §5's overload of one name for two shapes.

## Object identity

`transaction.accountChanges[i]` and `instruction.accounts.<name>.change` are the
**same object** for the same account. Payloads sharing a `(slot,
transactionIndex)` already share one transaction object via `groupBatchItems` /
`applyTransactionGroups`; the account objects are built once per transaction and
referenced. Identity comparison works, and a transaction with many instructions
holds one copy.

## Removed

| Removed | Reason |
| --- | --- |
| `transaction.tokenBalances` | `accountChanges.filter(c => c.token)`; the split makes it free to drop |
| `token_balance_fields` config toggle | Selection moves to `fields` (§7) |
| `transaction.allAccounts` | Replaced by `accountKeys` + `accountChanges` |
| `params.extraAccounts` | Derivable from `accountArguments` beyond the schema's count |
| The `Account` left join | No key-list join; `accountChanges` orders by `accountIndex` |

Dropping the join also deletes the lookup-table special case: no `BTreeMap` of
unjoined rows, no address-order tail, and no forced `account_keys` fetch.

## Field selection (§7)

```ts
fields: {
  transaction: ["signature", "accountKeys", "accountChanges"],
  accountChange: ["isSigner", "postLamports", "token.mint"],
}
```

`account` singular becomes `accountChange`, naming the type it governs.
`accountKeys` and `accountArguments` are `string[]` and take no sub-selection.

This is what makes the split pay: `accountChanges` needs no transaction column,
so a token-flow indexer stops paying for the key table. The old `allAccounts`
always billed for both.

## Open

1. **`accountKeys` is incomplete.** It carries only the message's static keys —
   12% of instruction arguments and 11% of activity rows fall outside it, via
   address lookup tables. The wire serves `loaded_addresses_writable` and
   `loaded_addresses_readonly` separately. Decide whether `accountKeys` exposes
   the static column as-is (documented) or the resolved list
   (`static ++ ALT writable ++ ALT readonly`), which is what `accountIndex`
   indexes into and would make `accountKeys[accountIndex]` a valid lookup.
2. **`transaction.tokenChanges`** as a derived view over the same objects — one
   filter at materialisation, no extra fetch. Add only if handler code wants it
   often enough to earn a second name for the same rows.
3. **`token_state`** is served and authoritative; the implementation currently
   infers the token side from `mint` presence. Internal change, no payload
   impact.

## Asks for the HyperSync team

Everything §12 previously asked for is now served and populated, except:

- **`a6`…`a9` in the napi client.** Ours to fix: upstream filters through `a9`,
  `types.rs` stops at `a5`. Blocks named-account filters past position 5.
- **Populate `pre_balance`/`post_balance` on every row** — low priority. Only
  balance-snapshot use cases need it; flow analysis reads an absent native side
  as a zero delta, which is complete. Costs two `u64`s on 54% of rows.
