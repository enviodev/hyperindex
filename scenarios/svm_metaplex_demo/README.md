# SVM Metaplex Demo

Live indexer for Metaplex Token Metadata instructions on Solana mainnet. Powered by HyperSync — backfills tens of thousands of slots in seconds, then tails real time.

## What this indexes

Two instructions on the Metaplex Token Metadata program (`metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s`):

- `CreateMetadataAccountV3` (discriminator `0x21`) — new token metadata being attached to a mint.
- `UpdateMetadataAccountV2` (discriminator `0x0f`) — metadata being edited (image, name, update authority, etc).

## Quick start

```bash
# 1. From the repo root, build the cdylib (the envio NAPI addon).
cargo build --lib

# 2. (Optional) If you have CARGO_TARGET_DIR set, sync the artifact:
cp -f "$CARGO_TARGET_DIR/debug/libenvio.so" target/debug/libenvio.so

# 3. From this directory, bring Postgres up.
cd scenarios/svm_metaplex_demo
pnpm install
pnpm docker-up

# 4. Run codegen + start the indexer.
pnpm codegen
pnpm start
```

Tail the logs and you'll see `[Create]` / `[Update]` lines per matched instruction. Visit `http://localhost:8080` for the GraphQL playground.

## Demo prep

Before showing this, adjust `start_block` in `config.yaml` to ~30-60k slots below the current Solana head. Get the current head with:

```bash
curl -s https://solana.hypersync.xyz/height
```

A 30-60k slot backfill takes ~10-30s on a decent connection and produces a steady stream of console output.
