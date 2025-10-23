import { experimental_createEffect, S } from "envio";
import { UniswapV3Factory, UniswapV3Pool } from "generated";
import { createPublicClient, http, parseAbi } from "viem";
import { mainnet } from "viem/chains";

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
  },
);

UniswapV3Factory.PoolCreated.handler(async ({ event, context }) => {
  const token0Details = await context.effect(fetchTokenDetails, {
    token: event.params.token0,
  });

  const token1Details = await context.effect(fetchTokenDetails, {
    token: event.params.token1,
  });

  const entity = {
    id: `${event.chainId}_${event.params.pool}`,
    token0: event.params.token0,
    token0Decimals: token0Details.decimal,
    token1: event.params.token1,
    token1Decimals: token1Details.decimal,
    fee: event.params.fee,
    tickSpacing: event.params.tickSpacing,
    pool: event.params.pool,
  };

  context.UniswapV3Factory_PoolCreated.set(entity);
});

UniswapV3Factory.PoolCreated.contractRegister(({ event, context }) => {
  context.addUniswapV3Pool(event.params.pool);
});

UniswapV3Pool.Initialize.handler(async ({ event, context }) => {
  const entity = {
    id: `${event.chainId}_${event.srcAddress}`,
    sqrtPriceX96: event.params.sqrtPriceX96,
    tick: event.params.tick,
    pool: event.srcAddress,
    poolDetails: `${event.chainId}_${event.srcAddress}`,
  };

  context.UniswapV3Pool_Initialize.set(entity);
});