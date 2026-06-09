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
    id mint updateAuthority updateCount lastUpdatedSlot
  }
  ProgramStats { id totalInstructions createCount updateCount }
}
```

## What this teaches

- Declaring a Solana program + its instructions in `config.yaml`
  (`ecosystem: svm`, `experimental.programs[].instructions[]`).
- Using `indexer.onInstruction({program, instruction}, handler)` to receive
  positional accounts + raw instruction data.
- Persisting per-instruction state to a typed entity (`TokenMetadataAccount`)
  and a counter (`ProgramStats`).
