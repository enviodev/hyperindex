# onBlock API

*Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features*

The `onBlock` API of HyperIndex lets you run custom logic on every block or at fixed block intervals. This is useful for aggregations, time-series operations, and bulk updates.

In this example, we'll walk through how to use the `onBlock` handler to take a snapshot of a token's total supply every 1000 blocks.

## Creating the Handler

First, import `onBlock` from `generated`:

```ts
import { onBlock } from "generated";
````

The `onBlock` function takes two arguments:

1. **Options** – configure the handler's name, the chain it should run on, and interval-related settings such as `interval`, `startBlock`, and `stopBlock`.
2. **Handler function** – contains your custom logic. Similar event handlers, it has access to relevant data, which in this case is block values like `timestamp` and `chainId`.

Example usage:

```ts
onBlock(
    {
        name: "MY_BLOCK_HANDLER",
        chain: CHAIN_ID,
        interval: BLOCK_INTERVAL
    },
    async ({ block, context }) => {
        // your onBlock logic here
    }
)
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