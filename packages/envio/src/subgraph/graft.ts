export type Graft = { base: string; block: number };

type Manifest = { startBlocks: number[]; graft: Graft | null };

const GATEWAYS = [
  "https://api.thegraph.com/ipfs/api/v0/cat?arg=",
  "https://ipfs.network.thegraph.com/api/v0/cat?arg=",
];
const MAX_CHAIN = 8;

async function fetchFromGateways(hash: string): Promise<string | null> {
  for (const gateway of GATEWAYS) {
    try {
      const response = await fetch(gateway + hash, {
        method: "POST",
        signal: AbortSignal.timeout(8000),
      });
      if (response.ok) return await response.text();
    } catch {
      // try the next gateway
    }
  }
  return null;
}

/** The start blocks and graft of a deployment manifest, read without a YAML parser. */
export function readManifest(text: string): Manifest {
  const startBlocks = [...text.matchAll(/^\s*startBlock:\s*["']?(\d+)/gm)].map((m) => Number(m[1]));
  const block = /^graft:\s*\n((?:[ \t]+.*\n?)+)/m.exec(text)?.[1] ?? "";
  const base = /^\s*base:\s*["']?(Qm[A-Za-z0-9]+)/m.exec(block)?.[1];
  const at = /^\s*block:\s*["']?(\d+)/m.exec(block)?.[1];
  return { startBlocks, graft: base && at ? { base, block: Number(at) } : null };
}

/**
 * graph-node copies the base deployment's data up to the graft block, and the
 * manifest on IPFS is the only record of where that base started. If it
 * started earlier than any data source here does, a re-index from these start
 * blocks is missing everything in between; the numbers go in the warning.
 * Returns null when the base can't be read (offline, pruned from IPFS).
 */
export async function graftBaseNotice(
  graft: Graft,
  ownStartBlocks: number[],
  fetchManifest: (hash: string) => Promise<string | null> = fetchFromGateways,
): Promise<string | null> {
  let earliest: number | null = null;
  let hash: string | null = graft.base;
  for (let depth = 0; hash && depth < MAX_CHAIN; depth++) {
    const text = await fetchManifest(hash);
    if (text === null) return null;
    const manifest = readManifest(text);
    if (manifest.startBlocks.length > 0) {
      const lowest = Math.min(...manifest.startBlocks);
      earliest = earliest === null ? lowest : Math.min(earliest, lowest);
    }
    hash = manifest.graft?.base ?? null;
  }
  if (earliest === null) return null;
  const own = ownStartBlocks.length > 0 ? Math.min(...ownStartBlocks) : 0;
  if (earliest < own) {
    return (
      `WARNING, DATA IS MISSING: the graft base ${graft.base} (read from IPFS) starts at block ` +
      `${earliest}, but the earliest startBlock here is ${own}. Blocks ${earliest} to ${own - 1} ` +
      `are in the grafted deployment and will not be indexed. Lower the startBlock of the data ` +
      `sources to ${earliest} to rebuild that history.`
    );
  }
  return (
    `The graft base ${graft.base} (read from IPFS) starts at block ${earliest}, not after this ` +
    `manifest's earliest startBlock ${own}: a re-index covers the same blocks.`
  );
}
