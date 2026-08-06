import { PairCreated, Factory } from "../generated/Factory/Factory";
import { Pair as PairTemplate } from "../generated/templates";
import { Pair, Tick } from "../generated/schema";
import { ethereum } from "@graphprotocol/graph-ts";

export function handlePairCreated(event: PairCreated): void {
  PairTemplate.create(event.params.pair);

  const name = Factory.bind(event.address).try_name();

  // `graph codegen` emits `changetype<Pair | null>(store.get(...))`, so what
  // comes back here carries no generated prototype.
  const previous = Pair.load(event.params.pair);

  const pair = new Pair(event.params.pair);
  pair.token0 = event.params.token0;
  pair.token1 = event.params.token1;
  pair.name = name.reverted
    ? "unknown"
    : previous === null
      ? name.value
      : previous.name + "+" + name.value;
  pair.save();
}

export function handleBlock(block: ethereum.Block): void {
  const tick = new Tick(block.number.toString());
  tick.height = block.number;
  tick.save();
}
