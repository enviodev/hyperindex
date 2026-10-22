// A manifest's mapping file can re-export handlers written elsewhere — SSV's
// `src/mapping.ts` is `export { handleValidatorAdded } from "./handlers/..."`.
// The event a handler gets is built as the generated class it declares, read
// off the module the handler is written in; the runtime only looked at the
// manifest's file, so a re-exported handler got a bare `ethereum.Event`, its
// `params` lost graph codegen's getters, and a struct field read undefined.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Network
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Network
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Cluster
      abis:
        - name: Network
          file: ./abis/Network.json
      eventHandlers:
        - event: ValidatorAdded(indexed address,(uint32,uint64))
          handler: handleValidatorAdded
      file: ./src/mapping.ts
`,
  ~schema=`
type Cluster @entity {
  id: ID!
  validatorCount: BigInt!
  index: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Network.json",
      `[{"type":"event","name":"ValidatorAdded","anonymous":false,"inputs":[{"name":"owner","type":"address","indexed":true},{"name":"cluster","type":"tuple","indexed":false,"components":[{"name":"validatorCount","type":"uint32"},{"name":"index","type":"uint64"}]}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "generated/Network/Network.ts",
      `
import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts";

export class ValidatorAdded extends ethereum.Event {
  get params(): ValidatorAdded__Params {
    return new ValidatorAdded__Params(this);
  }
}

export class ValidatorAdded__Params {
  _event: ValidatorAdded;
  constructor(event: ValidatorAdded) {
    this._event = event;
  }
  get owner(): Address {
    return this._event.parameters[0].value.toAddress();
  }
  get cluster(): ValidatorAddedClusterStruct {
    return changetype<ValidatorAddedClusterStruct>(this._event.parameters[1].value.toTuple());
  }
}

export class ValidatorAddedClusterStruct extends ethereum.Tuple {
  get validatorCount(): BigInt {
    return this[0].toBigInt();
  }
  get index(): BigInt {
    return this[1].toBigInt();
  }
}
`,
    ),
    (
      "src/handlers/validator.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { ValidatorAdded as ValidatorAddedEvent } from "../../generated/Network/Network";

export function handleValidatorAdded(event: ValidatorAddedEvent): void {
  let cluster = new Entity();
  cluster.setBigInt("validatorCount", event.params.cluster.validatorCount);
  cluster.setBigInt("index", event.params.cluster.index);
  store.set("Cluster", event.params.owner.toHexString(), cluster);
}
`,
    ),
    ("src/mapping.ts", `export { handleValidatorAdded } from "./handlers/validator";
`),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const owner = "0x2222222222222222222222222222222222222222";

describe("a handler the manifest's mapping file re-exports", () => {
  it("gets the event as the generated class it declares", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Network",
              event: "ValidatorAdded",
              params: { owner, cluster: { validatorCount: 3n, index: 9n } },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Cluster.getAll()).toEqual([{ id: owner, validatorCount: 3n, index: 9n }]);
  });
});
`,
)
