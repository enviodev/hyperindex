/*
 *Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
 */

import { SwapContract } from "generated";

SwapContract.Swap.handler(async ({ event, context }) => {
  context.EventTracker.set({
    id: "eventTracker",
    count: 1,
  });

  context.Swap.set({
    id: event.transaction.hash + event.logIndex,
    recipient: event.params.recipient,
    sender: event.params.sender,
    amount0: event.params.amount0,
    amount1: event.params.amount1,
    sqrtPriceX96: event.params.sqrtPriceX96,
    liquidity: event.params.liquidity,
    tick: event.params.tick,
    blockNumber: event.block.number,
    blockTimestamp: event.block.timestamp,
    transactionHash: event.transaction.hash,
  });
});
