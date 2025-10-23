# Effects API

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

With HyperIndex, the Effects API allows you to perform external calls from your handlers.
These calls run in parallel with your handler logic, so they don’t block execution.

You can learn more about the Effects API in the documentation: [https://docs.envio.dev/docs/HyperIndex/effect-api](https://docs.envio.dev/docs/HyperIndex/effect-api)

The following example extends the **factory pattern** example to fetch the **decimal of a token** using an RPC call via **Viem**.

## Create Effect

To create an effect in your handler, use the `experimental_createEffect` function from the `envio` package.
This function takes **two arguments**: effect options and a handler function.

Effect options:

* `name`: used for debugging and logging
* `input`: the input type of the effect
* `output`: the output type of the effect
* `cache`: whether to cache the effect result in the database

## Using Effect

To use the effect, use `context.effect` from your handlers, loaders, or other effects:

```ts
CONTRACT.EVENT.handler(async ({ event, context }) => {
  const effectOutput = await context.effect(YOUR_EFFECT, EFFECT_INPUTS);
});
```

## `getTokenDetails` Effect

The following effect fetches the **decimal of a token** using an RPC call:

```ts
const client = createPublicClient({
  chain: mainnet,
  transport: http(process.env.ETHEREUM_MAINNET_RPC!),
});

const ERC20_ABI = parseAbi(["function decimals() view returns (uint8)"]);

const fetchTokenDetails = experimental_createEffect(
  {
    name: "fetchTokenDetails",
    input: {
      token: S.string,
    },
    output: {
      decimal: S.number,
    },
  },
  async ({ input }) => {
    const decimals = await client.readContract({
      address: input.token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "decimals",
    });

    console.log(`Token decimals: ${decimals}`);
    return { decimal: decimals };
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