# Effect API

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

With HyperIndex, the Effect API allows you to perform external calls from your handlers.
These calls are executed within the handler context and support optional caching and rate limiting.

You can learn more about the Effect API in the [documentation](https://docs.envio.dev/docs/HyperIndex/effect-api).

The following example extends the **factory pattern** example to fetch the **decimal of a token** via an RPC call, indexing Uniswap V3 `PoolCreated` events across Ethereum Mainnet and Arbitrum.

## Create Effect

To create an effect in your handler, use the `createEffect` function from the `envio` package.
This function takes **two arguments**: effect options and a handler function.

Effect options:

- `name`: used for debugging and logging
- `input`: the input type of the effect
- `output`: the output type of the effect
- `cache`: whether to cache the effect result in the database
- `rateLimit`: limits the execution frequency of this effect, read more in the [documentation](https://docs.envio.dev/docs/HyperIndex/effect-api#rate-limit)

## Using Effect

To use the effect, use `context.effect` from your handlers, loaders, or other effects:

```ts
CONTRACT.EVENT.handler(async ({ event, context }) => {
  const effectOutput = await context.effect(YOUR_EFFECT, EFFECT_INPUTS);
});
```

## `fetchTokenDetails` Effect

The following effect fetches the **decimal of a token** using an RPC call:

```ts
const fetchTokenDetails = createEffect(
  {
    name: "fetchTokenDetails", // Name used internally for the effect
    input: {
      token: S.string, // Input: token address as string
      chainId: S.number, // Input: chain ID to select the right RPC client
    },
    output: {
      decimal: S.number, // Output: decimal value for the token
    },
    rateLimit: false, // Disable rate limiting for this effect
  },
  async ({ input, context }) => {
    try {
      const client = CHAIN_CLIENTS[input.chainId];
      if (!client) {
        context.log.warn(`No RPC client configured for chainId ${input.chainId}`);
        return { decimal: 18 };
      }

      // Call token.decimals() via RPC
      const decimals = await client.readContract({
        address: input.token as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "decimals",
      });

      return { decimal: Number(decimals) };
    } catch (err) {
      // Log a warning instead of failing the entire event
      context.log.warn(
        `⚠️ Failed to fetch token decimals for ${input.token}: ${err}`
      );

      // Fallback: most tokens use 18 decimals
      return { decimal: 18 };
    }
  }
);
```

## Prerequisites

Before running the indexer locally, make sure you have the following installed:

- **[Node.js 18+](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**

## Running the Indexer

Add your Envio API key and RPC URLs to the `.env` file, then start the indexer:

```bash
pnpm dev
```

If you make changes to `config.yaml` or `schema.graphql`, regenerate the type files:

```bash
pnpm codegen
```

## GraphQL Playground

While indexer is running, visit the [Envio Console](https://envio.dev/console) to open the GraphQL Playground and query your indexed data.
