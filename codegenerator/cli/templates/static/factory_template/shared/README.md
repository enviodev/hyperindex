# Factory Indexer

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

With **HyperIndex**, developers can index contracts **deployed from factory contracts** without specifying their addresses in advance. A common example of the factory pattern is **Uniswap V3**, which deploys new pool contracts through its factory.

This example demonstrates how to index **Uniswap V3 Pools** created by the **Uniswap V3 Factory** on **Ethereum Mainnet**.

For more information, see the [dynamic contracts documentation](https://docs.envio.dev/docs/HyperIndex/dynamic-contracts).

## Contract Registration

To index contracts deployed from a factory, use the `contractRegister` handler on the event that emits the deployed contract’s address. Within the handler, use the `context` object to register the new contract with the indexer.

Example:

```ts
<contract-name>.<event-name>.contractRegister(({ event, context }) => {
  context.add<your-contract-name>(<address-of-the-contract>);
});
```

In the case of **Uniswap V3 Factory**, the handler looks like this:

```ts
// src/handlers/UniswapV3Factory.ts
UniswapV3Factory.PoolCreated.contractRegister(({ event, context }) => {
  context.addUniswapV3Pool(event.params.pool);
});
```

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

- **[Node.js 22+](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**

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
