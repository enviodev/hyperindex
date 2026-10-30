// Refreshes src/subgraph/graph_networks.json from The Graph's networks
// registry, which is what a subgraph.yaml's `network:` names. With `--check`
// it only reports whether the snapshot has drifted, for CI.
import { readFileSync, writeFileSync } from "node:fs";

const REGISTRY = "https://networks-registry.thegraph.com/TheGraphNetworksRegistry.json";
const SNAPSHOT = new URL("../src/subgraph/graph_networks.json", import.meta.url);

const registry = await (await fetch(REGISTRY)).json();

// Only EVM networks: the translator refuses the rest by name.
const networks = Object.fromEntries(
  registry.networks
    .filter((network) => network.caip2Id?.startsWith("eip155:"))
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((network) => [
      network.id,
      { chainId: Number(network.caip2Id.slice("eip155:".length)), aliases: network.aliases ?? [] },
    ]),
);
const snapshot = `${JSON.stringify(networks, null, 2)}\n`;

if (!process.argv.includes("--check")) {
  writeFileSync(SNAPSHOT, snapshot);
  console.log(`Wrote ${Object.keys(networks).length} networks from registry ${registry.version}.`);
} else if (readFileSync(SNAPSHOT, "utf8") !== snapshot) {
  console.error(
    `The Graph's networks registry (${registry.version}) has changed since ` +
      "src/subgraph/graph_networks.json was taken. Refresh it:\n" +
      "  node packages/cli/scripts/sync-graph-networks.mjs",
  );
  process.exit(1);
} else {
  console.log(`graph_networks.json matches registry ${registry.version}.`);
}
