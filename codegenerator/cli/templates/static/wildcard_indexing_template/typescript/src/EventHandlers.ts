import { ERC20 } from "generated";

ERC20.Transfer.handler(
  async ({ event, context }) => {
    context.Transfer.set({
      id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
      amount: event.params.value,
      from: event.params.from,
      to: event.params.to,
      contract: event.srcAddress,
    });
  },
  { wildcard: true },
);