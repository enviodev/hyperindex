/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { UniswapV3Pool, UniswapV3Pool_Swap } from "generated";

// Handle Swap events emitted by the registered Uniswap V3 pools
UniswapV3Pool.Swap.handler(async ({ event, context }) => {
  const entity: UniswapV3Pool_Swap = {
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`, // Unique swap ID
    chainId: event.chainId,                                           // Chain ID
    sqrtPriceX96: event.params.sqrtPriceX96,                        // Post-swap sqrt price
    liquidity: event.params.liquidity,                              // Liquidity after the swap
    amount0: event.params.amount0,                                  // Token0 delta
    amount1: event.params.amount1,                                  // Token1 delta
    sender: event.params.sender,                                    // Swap initiator
    recipient: event.params.recipient,                              // Swap output recipient
    pool: event.srcAddress,                                         // Pool address
  };

  context.UniswapV3Pool_Swap.set(entity);                           // Store swap entity
});