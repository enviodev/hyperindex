import {
  Address,
  BigInt,
  DataSourceTemplate,
  Entity,
  ethereum,
  store,
} from "@graphprotocol/graph-ts";

// What `graph codegen` emits for a contract binding: a SmartContract subclass
// whose methods go through call/tryCall.
class Factory extends ethereum.SmartContract {
  static bind(address: Address): Factory {
    return new Factory("Factory", address);
  }

  try_name(): any {
    return this.tryCall("name", "name():(string)", []);
  }
}

export function handlePairCreated(event: any): void {
  DataSourceTemplate.create("Pair", [event.params.pair.toHexString()]);

  const name = Factory.bind(event.address).try_name();

  const pair = new Entity();
  pair.setBytes("token0", event.params.token0);
  pair.setBytes("token1", event.params.token1);
  pair.setString("name", name.reverted ? "unknown" : name.value[0].toString());
  store.set("Pair", event.params.pair.toHexString(), pair);
}

export function handleBlock(block: any): void {
  const tick = new Entity();
  tick.setBigInt("height", block.number);
  store.set("Tick", block.number.toString(), tick);
}
