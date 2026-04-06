/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { ERC20 } from "generated";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

ERC20.Transfer.handler(
  async ({ event, context }) => {
    context.Transfer.set({
      id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
      amount: event.params.value,
      from: event.params.from,
      to: event.params.to,
      contract: event.srcAddress,
      chainId: event.chainId,
    });
  },
  {
    wildcard: true,
    eventFilters: () => {
      // Mint: transfer FROM zero address; Burn: transfer TO zero address
      return [{ from: ZERO_ADDRESS }, { to: ZERO_ADDRESS }];
    },
  }
);
