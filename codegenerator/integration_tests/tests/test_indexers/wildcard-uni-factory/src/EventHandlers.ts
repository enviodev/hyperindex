import { UniswapV3Factory } from "generated";

const DAI_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
UniswapV3Factory.PoolCreated.handler(
  async ({ event, context }) => {
    context.PoolCreated.set({
      id: event.transaction.hash + event.logIndex.toString(),
      token0: event.params.token0,
      token1: event.params.token1,
      fee: event.params.fee,
      tickSpacing: event.params.tickSpacing,
      pool: event.params.pool,
    });
  },
  {
    wildcard: true,
    eventFilters: [{ token0: DAI_ADDRESS }, { token1: DAI_ADDRESS }],
  },
);
