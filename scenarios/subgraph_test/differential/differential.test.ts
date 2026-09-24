// Run by run.sh inside a copy of the scenario, after graph-node has indexed the
// chain: envio indexes the same blocks, and every entity must come out the
// same, field for field.
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const graphUrl = process.env.GRAPH_QUERY_URL!;
const endBlock = Number(process.env.END_BLOCK);

// Every stored field of every entity; derived fields are views over these.
const QUERY = `{
  pairs(first: 1000, orderBy: id) { id token0 token1 name }
  pairMetadatas: pairMetadata_collection(first: 1000, orderBy: id) { id pair { id } label }
  swaps(first: 1000, orderBy: id) { id pair { id } sender amount }
  ticks(first: 1000, orderBy: id) { id height }
}`;

/** An envio row in the shape graph-node's GraphQL answers with. */
function asGraphNode(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    const field = key.endsWith("_id") ? key.slice(0, -3) : key;
    const plain =
      value instanceof Uint8Array
        ? `0x${Buffer.from(value).toString("hex")}`
        : typeof value === "bigint"
          ? value.toString()
          : value;
    out[field] = key.endsWith("_id") ? { id: plain } : plain;
  }
  return out;
}

const byId = (rows: Record<string, unknown>[]) =>
  rows.map(asGraphNode).sort((a, b) => String(a.id).localeCompare(String(b.id)));

describe("the scenario on graph-node and on envio", () => {
  it("stores the same entities", async () => {
    const response = await fetch(graphUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: QUERY }),
    });
    const { data, errors } = (await response.json()) as { data: any; errors?: unknown };
    expect(errors).toBeUndefined();

    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 0, endBlock } } });

    // graph-node sorts its ids as strings too, but by their own collation.
    const graphNode = Object.fromEntries(
      Object.entries(data as Record<string, Record<string, unknown>[]>).map(([name, rows]) => [
        name,
        [...rows].sort((a, b) => String(a.id).localeCompare(String(b.id))),
      ]),
    );
    expect({
      pairs: byId(await indexer.Pair.getAll()),
      pairMetadatas: byId(await indexer.PairMetadata.getAll()),
      swaps: byId(await indexer.Swap.getAll()),
      ticks: byId(await indexer.Tick.getAll()),
    }).toEqual(graphNode);
  });
});
