/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { UniswapV3Factory } from "generated";

// Register the newly created pool so HyperIndex listens to its events
UniswapV3Factory.PoolCreated.contractRegister(({ event, context }) => {
  context.addUniswapV3Pool(event.params.pool); // Begin indexing this pool
});
