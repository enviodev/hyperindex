import { Swap as SwapEvent } from "../generated/templates/Pair/Pair";
import { Swap } from "../generated/schema";

export function handleSwap(event: SwapEvent): void {
  const swap = new Swap(event.address.toHexString() + "-" + event.logIndex.toString());
  swap.pair = event.address;
  swap.sender = event.params.sender;
  swap.amount = event.params.amount;
  swap.save();
}
