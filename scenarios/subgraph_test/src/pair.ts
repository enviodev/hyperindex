import { Swap as SwapEvent } from "../generated/templates/Pair/Pair";
import { Pair, PairMetadata, Swap } from "../generated/schema";

export function handleSwap(event: SwapEvent): void {
  const swap = new Swap(event.address.toHexString() + "-" + event.logIndex.toString());
  swap.pair = event.address;
  swap.sender = event.params.sender;
  swap.amount = event.params.amount;
  swap.save();

  const metadata = new PairMetadata(event.address.toHexString());
  metadata.pair = event.address;
  metadata.label = "seen";
  metadata.save();

  // Both derived fields load as arrays, list or one-to-one, and both are read
  // back through the loader `graph codegen` emitted for them.
  const pair = Pair.load(event.address)!;
  const label = pair.metadata.load()[0].label;
  pair.name = pair.name + "/" + label + pair.swaps.load().length.toString();
  pair.save();
}
