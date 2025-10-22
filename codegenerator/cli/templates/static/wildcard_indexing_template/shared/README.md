# Wildcard Indexing Template

_For a complete guide to all [Envio](https://envio.dev) indexer features, visit the [documentation website](https://docs.envio.dev)._

With **HyperIndex**, developers can enable **wildcard indexing**, allowing them to index events from **any contract** that matches a given event signature.
This is especially useful when working with contracts that follow common standards like **ERC20**, **ERC721**, or **ERC1155**.

You can learn more about wildcard indexing in the documentation: [https://docs.envio.dev/docs/HyperIndex/wildcard-indexing](https://docs.envio.dev/docs/HyperIndex/wildcard-indexing)

To enable wildcard indexing, simply pass `wildcard: true` in the handler configuration:

```ts
ERC20.Transfer.handler(
    async ({ event, context }) => {
        // ...your handler logic
    },
    { wildcard: true }
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