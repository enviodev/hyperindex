# Topic Filtering

_For a complete guide to all [Envio](https://envio.dev) indexer features, visit the [documentation website](https://docs.envio.dev)._

This example builds on our wildcard indexing example, which demonstrates how to index all events that match a given event signature.

In this version, we add an additional feature that filters those events further based on specific topics within the event data.

You can learn more about Topic Filtering in the documentation: [https://docs.envio.dev/docs/HyperIndex/wildcard-indexing#topic-filtering](https://docs.envio.dev/docs/HyperIndex/wildcard-indexing#topic-filtering)

To enable topic filtering, simply pass `eventFilters: { TOPIC_NAME: TOPIC_VALUE }` in the handler configuration.

```ts
ERC20.Transfer.handler(
    async ({ event, context }) => {
        // ...your handler logic
    },
    { 
        wildcard: true, 
        eventFilters: { 
            TOPIC_NAME: TOPIC_VALUE
        } 
    }
);
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