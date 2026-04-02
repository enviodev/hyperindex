# Topic Filter Indexer

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

With **HyperIndex**, developers can index events matching a specific signature **across all contracts** on a chain — without specifying contract addresses in advance. Combined with **topic filtering**, this lets you efficiently capture only the events you care about.

This example indexes ERC20 **mint** (Transfer from the zero address) and **burn** (Transfer to the zero address) events across **all ERC20 contracts** on Ethereum Mainnet and Polygon, using wildcard mode and per-chain event filters.

For more information, see:
- [Wildcard indexing documentation](https://docs.envio.dev/docs/HyperIndex/wildcard-indexing)
- [Event filters documentation](https://docs.envio.dev/docs/HyperIndex/event-filters)

## Wildcard Mode

To index all contracts matching an ABI, omit the address in the chain contract config:

```yaml
chains:
  - id: 1
    contracts:
      - name: ERC20
        # No address = wildcard mode (indexes ALL matching events on the chain)
```

In the handler, pass `wildcard: true` and use `event.srcAddress` to identify the source contract:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => {
    const tokenAddress = event.srcAddress; // The actual ERC20 contract address
    // ...
  },
  { wildcard: true }
);
```

## Topic Filtering

Use `eventFilters` to reduce event volume. The function form allows per-chain configuration using `chainId`:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: ({ chainId }) => {
      if (chainId !== 1 && chainId !== 137) return false;
      // OR: match mints (from zero address) or burns (to zero address)
      return [{ from: ZERO_ADDRESS }, { to: ZERO_ADDRESS }];
    },
  }
);
```

Each filter object in the array is **OR'd** together. Fields within a filter are **AND'd**.

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

- **[Node.js v22+ (v24 recommended)](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker](https://www.docker.com/products/docker-desktop/)** or **[Podman](https://podman.io/)**

## Running the Indexer

Add your Envio API key to the .env file, then start the indexer:

```bash
pnpm dev
```

If you make changes to `config.yaml` or `schema.graphql`, regenerate the type files:

```bash
pnpm codegen
```

## GraphQL Playground

While the indexer is running, visit the Envio Console([https://envio.dev/console](https://envio.dev/console)) to open the GraphQL Playground and query your indexed data.
