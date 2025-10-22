/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { UniswapV3Factory, UniswapV3Pool } from "generated";

UniswapV3Factory.PoolCreated.handler(async ({ event, context }) => {
    const entity = {
        id: `${event.chainId}_${event.params.pool}`,
        token0: event.params.token0,
        token1: event.params.token1,
        fee: event.params.fee,
        tickSpacing: event.params.tickSpacing,
        pool: event.params.pool,
    };

    context.UniswapV3Factory_PoolCreated.set(entity);
});

UniswapV3Factory.PoolCreated.contractRegister(({ event, context }) => {
    context.addUniswapV3Pool(event.params.pool);
});

UniswapV3Pool.Swap.handler(async ({ event, context }) => {
    const entity = {
        id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
        sqrtPriceX96: event.params.sqrtPriceX96,
        liquidity: event.params.liquidity,
        amount0: event.params.amount0,
        amount1: event.params.amount1,
        sender: event.params.sender,
        recipient: event.params.recipient,
        pool: event.srcAddress,
    };

    context.UniswapV3Pool_Swap.set(entity);
});