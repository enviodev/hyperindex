/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import {
  UniswapV3Factory,
  UniswapV3Factory_PoolCreated,
} from "generated";


UniswapV3Factory.PoolCreated.handler(async ({ event, context }) => {
  const entity: UniswapV3Factory_PoolCreated = {
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    chainId: event.chainId,
    pool: event.params.pool,
  };

  context.UniswapV3Factory_PoolCreated.set(entity);
});
