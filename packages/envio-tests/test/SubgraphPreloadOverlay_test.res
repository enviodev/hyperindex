// Registered(n) creates agent n and URIUpdated(n), the next log, reads it and
// makes a call (agent0's registry: an IPFS fetch). Preloaded against the store
// as it was before the batch, every URIUpdated finds no agent and returns, and
// re-preloading it once its agent exists is too late: it executes right after.
// So preload sees what the batch's earlier events wrote in their own preload,
// and the calls go out together. Preload's writes stay its own: execute runs
// against the real store, so the results are the same.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:4832")]),
  ~manifest=`
specVersion: 1.2.0
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
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Agent
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Registered(uint256)
          handler: handleRegistered
        - event: URIUpdated(uint256)
          handler: handleUriUpdated
      file: ./src/registry.ts
`,
  ~schema=`
type Agent @entity {
  id: ID!
  uri: BigInt
  updates: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Registered","anonymous":false,"inputs":[{"name":"agentId","type":"uint256","indexed":false}]},{"type":"event","name":"URIUpdated","anonymous":false,"inputs":[{"name":"agentId","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Address, BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

class Registry extends ethereum.SmartContract {
  static bind(address: Address): Registry {
    return new Registry("Registry", address);
  }
  uri(id: BigInt): BigInt {
    let result = super.call("uri", "uri(uint256):(uint256)", [ethereum.Value.fromUnsignedBigInt(id)]);
    return result[0].toBigInt();
  }
}

export function handleRegistered(event: any): void {
  let id: BigInt = event.params.agentId;
  let agent = new Entity();
  agent.setString("id", id.toString());
  agent.setBigInt("updates", BigInt.fromI32(0));
  store.set("Agent", id.toString(), agent);
}

export function handleUriUpdated(event: any): void {
  let id: BigInt = event.params.agentId;
  let agent = store.get("Agent", id.toString());
  if (agent == null) return;
  agent.setBigInt("uri", Registry.bind(event.address).uri(id));
  agent.setBigInt("updates", agent.getBigInt("updates").plus(BigInt.fromI32(1)));
  store.set("Agent", id.toString(), agent);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const AGENTS = 8;

let server: Server;
// Calls being answered at once, whether they came alone or in a batch.
let inFlight = 0;
let peak = 0;

// uri(n) answers 5n.
const answer = (request: any) => ({
  jsonrpc: "2.0",
  id: request.id,
  result: "0x" + (5n * BigInt("0x" + request.params[0].data.slice(10))).toString(16).padStart(64, "0"),
});

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      const calls = Array.isArray(parsed) ? parsed.length : 1;
      inFlight += calls;
      peak = Math.max(peak, inFlight);
      setTimeout(() => {
        inFlight -= calls;
        res.end(JSON.stringify(Array.isArray(parsed) ? parsed.map(answer) : answer(parsed)));
      }, 40);
    });
  });
  await new Promise<void>((resolve) => server.listen(4832, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("a handler reading what the previous event of the batch created", () => {
  it("has its call preloaded with the others", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: Array.from({ length: AGENTS }, (_, index) => [
            { contract: "Registry", event: "Registered", params: { agentId: BigInt(index + 1) } },
            { contract: "Registry", event: "URIUpdated", params: { agentId: BigInt(index + 1) } },
          ]).flat(),
        },
      },
    });

    const agents = (await indexer.Agent.getAll())
      .map((agent: any) => ({ id: agent.id, uri: agent.uri, updates: agent.updates }))
      .sort((a: any, b: any) => Number(a.id) - Number(b.id));
    t.expect({ agents, together: peak >= AGENTS / 2 }).toEqual({
      agents: Array.from({ length: AGENTS }, (_, index) => ({
        id: String(index + 1),
        uri: 5n * BigInt(index + 1),
        updates: 1n,
      })),
      together: true,
    });
  });
});
`,
)
