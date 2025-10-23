/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import {
    UniswapV3Factory,
    UniswapV3Factory_FeeAmountEnabled,
    UniswapV3Factory_OwnerChanged,
    UniswapV3Factory_PoolCreated,
} from "generated";

UniswapV3Factory.FeeAmountEnabled.handler(async ({ event, context }) => {
    const entity: UniswapV3Factory_FeeAmountEnabled = {
        id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
        fee: event.params.fee,
        tickSpacing: event.params.tickSpacing,
    };

    context.UniswapV3Factory_FeeAmountEnabled.set(entity);
});

UniswapV3Factory.OwnerChanged.handler(async ({ event, context }) => {
    const entity: UniswapV3Factory_OwnerChanged = {
        id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
        oldOwner: event.params.oldOwner,
        newOwner: event.params.newOwner,
    };

    context.UniswapV3Factory_OwnerChanged.set(entity);
});

UniswapV3Factory.PoolCreated.handler(async ({ event, context }) => {
    const entity: UniswapV3Factory_PoolCreated = {
        id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
        token0: event.params.token0,
        token1: event.params.token1,
        fee: event.params.fee,
        tickSpacing: event.params.tickSpacing,
        pool: event.params.pool,
    };

    context.UniswapV3Factory_PoolCreated.set(entity);
});