import { createEffect, S } from "envio";
import { indexer } from "generated";
import { createPublicClient, http, parseAbi } from "viem";
import { arbitrum, mainnet } from "viem/chains";

// Create Viem clients per chain for RPC reads
const CHAIN_CLIENTS: Record<number, ReturnType<typeof createPublicClient>> = {
  1: createPublicClient({
    chain: mainnet,
    transport: http(process.env.ENVIO_ETHEREUM_MAINNET_RPC!, { batch: true }),
  }),
  42161: createPublicClient({
    chain: arbitrum,
    transport: http(process.env.ENVIO_ARBITRUM_RPC!, { batch: true }),
  }),
};

// Minimal ABI to fetch ERC20 decimals
const ERC20_ABI = parseAbi(["function decimals() view returns (uint8)"]);

// Effect to fetch token metadata (decimals)
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
        context.log.warn(
          `No RPC client configured for chainId ${input.chainId}`,
        );
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
        `⚠️ Failed to fetch token decimals for ${input.token}: ${err}`,
      );

      // Fallback: most tokens use 18 decimals
      return { decimal: 18 };
    }
  },
);

// Handle Uniswap V3 PoolCreated event
indexer.onEvent(
  { contract: "UniswapV3Factory", event: "PoolCreated" },
  async ({ event, context }) => {
    // Run both token decimal fetches in parallel
    const [token0Details, token1Details] = await Promise.all([
      context.effect(fetchTokenDetails, {
        token: event.params.token0,
        chainId: event.chainId,
      }),
      context.effect(fetchTokenDetails, {
        token: event.params.token1,
        chainId: event.chainId,
      }),
    ]);

    // Entity data for indexing
    const entity = {
      id: `${event.chainId}_${event.params.pool}`, // Unique ID (chain + pool address)
      token0: event.params.token0, // Token0 address
      token0Decimals: token0Details.decimal, // Fetched token0 decimals
      token1: event.params.token1, // Token1 address
      token1Decimals: token1Details.decimal, // Fetched token1 decimals
      fee: event.params.fee, // Fee tier
      tickSpacing: event.params.tickSpacing, // Pool tick spacing
      pool: event.params.pool, // Pool address
    };

    // Store entity
    context.UniswapV3Factory_PoolCreated.set(entity);
  },
);
