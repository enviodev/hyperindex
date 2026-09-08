# Solana Block Handler

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

This example demonstrates how to index **Solana blocks** using a block handler. Slots are streamed from HyperSync; the handler then fetches each block's data from a Solana RPC endpoint and stores it.

For more information, see the [block handlers documentation](https://docs.envio.dev/docs/HyperIndex/block-handlers).

## Slot Handler

The `indexer.onSlot` handler is triggered for each slot on every configured chain. This example uses an effect to fetch additional block data from the Solana RPC:

```ts
indexer.onSlot(
  { name: "BlockTracker" },
  async ({ slot, context }) => {
    const block = await context.effect(getBlockEffect, { slot });
    // Process block data...
  },
);
```

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

- **[Node.js v22+ (v24 recommended)](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker](https://www.docker.com/products/docker-desktop/)** or **[Podman](https://podman.io/)**

## Configuration

Add your Envio API token and a Solana RPC URL to the `.env` file:

```
ENVIO_API_TOKEN=<YOUR-API-TOKEN>
ENVIO_MAINNET_RPC_URL=https://your-svm-rpc-endpoint
```

The token authenticates the HyperSync source that streams slots; create one at
[envio.dev/app/api-tokens](https://envio.dev/app/api-tokens). The RPC URL is
read by the `getBlock` effect above, not by the data source.

## Running the Indexer

Start the indexer:

```bash
pnpm dev
```

If you make changes to `config.yaml` or `schema.graphql`, regenerate the type files:

```bash
pnpm codegen
```

## GraphQL Playground

While the indexer is running, visit the Envio Console ([https://envio.dev/console](https://envio.dev/console)) to open the GraphQL Playground and query your indexed data.
