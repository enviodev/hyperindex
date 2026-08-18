# Metaplex Token Metadata indexer

A HyperIndex starter that streams Metaplex Token Metadata
`CreateMetadataAccountV3` and `UpdateMetadataAccountV2` instructions off
Solana mainnet via HyperSync, and writes one row per metadata PDA.

## Quick start

```bash
pnpm install

# Adjust config.yaml `start_block` to ~30k slots below current head:
curl -s https://solana.hypersync.xyz/height

pnpm envio local docker up    # Postgres + Hasura
pnpm envio codegen
pnpm envio start
```

Open the GraphQL playground at `http://localhost:8080` and query:

```graphql
{
  TokenMetadataAccount(limit: 5, order_by: {lastUpdatedSlot: desc}) {
    id mint name symbol uri updateAuthority updateCount lastUpdatedSlot
  }
  ProgramStats { id totalInstructions createCount updateCount }
}
```

## What this teaches

- Declaring a Solana program + its instructions in `config.yaml`
  (`ecosystem: svm`, `experimental.programs[].instructions[]`).
- Attaching a program IDL (`idls/token-metadata.codama.json`, wired up by the
  `idl:` key in `config.yaml`) so instructions arrive decoded.
- Using `indexer.onInstruction({program, instruction}, handler)` and reading
  `instruction.params`, whose `accounts` are named and whose `args` are
  Borsh-decoded from the IDL. Without an IDL, `params` is absent and only the
  positional `instruction.accounts` and raw `instruction.data` arrive.
- Persisting per-instruction state to a typed entity (`TokenMetadataAccount`)
  and a counter (`ProgramStats`).
