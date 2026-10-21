// Generated bindings from graph-cli before 0.18 (mapping apiVersion 0.0.3 and
// older) call `super.call("ownerOf", [params])` with no function signature, and
// graph-node finds the function by name in the data source's ABI — the first of
// that name, overloads or not (chain/ethereum/src/runtime/runtime_adapter.rs,
// `function_signature: None` → `contract.function(name)`). The shim only took
// the three-argument call of later graph-ts.
let manifest = `
specVersion: 0.0.2
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.3
      language: wasm/assemblyscript
      entities:
        - Owner
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`

let schema = `
type Owner @entity {
  id: ID!
  owner: Bytes!
  paused: String!
}
`

let abi = `[
  {"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"node","type":"uint256","indexed":false}]},
  {"type":"function","name":"ownerOf","stateMutability":"view","inputs":[{"name":"node","type":"uint256"}],"outputs":[{"name":"","type":"address"}]},
  {"type":"function","name":"ownerOf","stateMutability":"view","inputs":[{"name":"node","type":"uint256"},{"name":"at","type":"uint256"}],"outputs":[{"name":"","type":"address"}]},
  {"type":"function","name":"paused","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"bool"}]}
]`

let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Registry.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Registry.json", abi),
    // graph-cli 0.17's output for the ABI above, committed.
    (
      "src/types/Registry/Registry.ts",
      `
import {
  EthereumEvent,
  SmartContract,
  EthereumValue,
  Address,
  BigInt,
  CallResult
} from "@graphprotocol/graph-ts";

export class NewOwner extends EthereumEvent {
  get params(): NewOwner__Params {
    return new NewOwner__Params(this);
  }
}

export class NewOwner__Params {
  _event: NewOwner;

  constructor(event: NewOwner) {
    this._event = event;
  }

  get node(): BigInt {
    return this._event.parameters[0].value.toBigInt();
  }
}

export class Registry extends SmartContract {
  static bind(address: Address): Registry {
    return new Registry("Registry", address);
  }

  ownerOf(node: BigInt): Address {
    let result = super.call("ownerOf", [EthereumValue.fromUnsignedBigInt(node)]);

    return result[0].toAddress();
  }

  try_paused(): CallResult<boolean> {
    let result = super.tryCall("paused", []);
    if (result.reverted) {
      return new CallResult();
    }
    let value = result.value;
    return CallResult.fromValue(value[0].toBoolean());
  }
}
`,
    ),
    (
      "src/registry.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";
import { NewOwner, Registry } from "./types/Registry/Registry";

export function handleNewOwner(event: NewOwner): void {
  let registry = Registry.bind(event.address);
  let paused = registry.try_paused();
  let owner = new Entity();
  owner.set("owner", Value.fromBytes(registry.ownerOf(event.params.node)));
  owner.set("paused", Value.fromString(paused.reverted ? "reverted" : "answered"));
  store.set("Owner", event.params.node.toString(), owner);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const OWNER_OF = "0x6352211e";
const PAUSED = "0x5c975abb";
const owner = "0x00000000000000000000000000000000000000aa";

let server: Server;
const calls: string[] = [];

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const requests = [JSON.parse(body)].flat();
      const answers = requests.map((request: any) => {
        const data: string = request.params?.[0]?.data ?? "";
        if (request.method === "eth_call") calls.push(data);
        if (request.method === "eth_call" && data.startsWith(OWNER_OF)) {
          return { jsonrpc: "2.0", id: request.id, result: "0x" + owner.slice(2).padStart(64, "0") };
        }
        if (request.method === "eth_call" && data.startsWith(PAUSED)) {
          return { jsonrpc: "2.0", id: request.id, error: { code: 3, message: "execution reverted" } };
        }
        return { jsonrpc: "2.0", id: request.id, result: "0x1" };
      });
      res.end(JSON.stringify(Array.isArray(JSON.parse(body)) ? answers : answers[0]));
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("a pre-0.18 contract binding", () => {
  it("calls the ABI's first function of that name", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { node: 5n }, block: { number: 12 } }] },
      },
    });

    t.expect({
      owners: await indexer.Owner.getAll(),
      ownerOf: calls.filter((data) => data.startsWith(OWNER_OF)).length > 0,
    }).toEqual({
      owners: [{ id: "5", owner: new Uint8Array(Buffer.from(owner.slice(2), "hex")), paused: "reverted" }],
      ownerOf: true,
    });
  });
});
`,
)
