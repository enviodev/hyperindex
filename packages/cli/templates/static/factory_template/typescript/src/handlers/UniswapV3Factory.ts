/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { indexer } from "envio";

// Register the newly created pool so HyperIndex listens to its events
indexer.contractRegister({ contract: "UniswapV3Factory", event: "PoolCreated" }, async ({ event, context }) => {
  context.chain.UniswapV3Pool.add(event.params.pool); // Begin indexing this pool
});
