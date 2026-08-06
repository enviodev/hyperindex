import { Entity, store } from "@graphprotocol/graph-ts";

export function handleSwap(event: any): void {
  const swap = new Entity();
  swap.setBytes("pair", event.address);
  swap.setBytes("sender", event.params.sender);
  swap.setBigInt("amount", event.params.amount);
  store.set("Swap", event.transaction.hash + "-" + event.logIndex.toString(), swap);
}
