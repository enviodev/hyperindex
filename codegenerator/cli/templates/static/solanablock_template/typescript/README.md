# Solana Block Handler

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

This example demonstrates how to index **Solana blocks** using a block handler. The handler fetches block data from a Solana RPC endpoint and stores block information.

For more information, see the [block handlers documentation](https://docs.envio.dev/docs/HyperIndex/block-handlers).

## Block Handler

The `onBlock` handler is triggered for each block at the specified interval. This example uses an effect to fetch additional block data from the Solana RPC:

```ts
onBlock({ chain: 0, name: "BlockTracker" }, async ({ slot, context }) => {
  const block = await context.effect(getBlockEffect, { slot });
  // Process block data...
});
```

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

- **[Node.js 22+](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**

## Configuration

Add your Solana RPC URL to the `.env` file:

```
ENVIO_MAINNET_RPC_URL=https://your-solana-rpc-endpoint
```

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
