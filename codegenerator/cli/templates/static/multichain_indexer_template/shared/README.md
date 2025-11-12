## Multichain Indexing

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

With **HyperIndex**, developers can index events emitted across **multiple chains** within a single indexer. This example demonstrates how to index the **Uniswap V3 Factory** contract across **Ethereum Mainnet**, **Arbitrum Mainnet**, and **Unichain Mainnet**.

You can learn more about multichain indexing in the documentation: [https://docs.envio.dev/docs/HyperIndex/multichain-indexing](https://docs.envio.dev/docs/HyperIndex/multichain-indexing).

To add more networks to your indexer, simply include an additional network entry in your `config.yaml`:

```yaml
- id: NETWORK_ID
  start_block: STARTING_BLOCK
  contracts:
      - name: YOUR_CONTRACT
        address:
            - CONTRACT_ADDRESS
```

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

-   **[Node.js 18+](https://nodejs.org/en/download/)**
-   **[pnpm](https://pnpm.io/installation)**
-   **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**

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

While indexer is running, visit the Envio Console([https://envio.dev/console](https://envio.dev/console)) to open the GraphQL Playground and query your indexed data.