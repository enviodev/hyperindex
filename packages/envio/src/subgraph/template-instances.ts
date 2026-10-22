import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";

type Instance = { address: string; block: number };

const instances = new Map<string, Instance[]>();
let loaded = false;

function file(): string {
  return path.join(process.cwd(), ".envio", "subgraph-template-instances.jsonl");
}

const keyOf = (chainId: number, template: string) => `${chainId}:${template}`;

function add(key: string, address: string, block: number): boolean {
  const list = instances.get(key) ?? [];
  const known = list.find((instance) => instance.address === address);
  if (known) {
    if (known.block === block) return false;
    known.block = block;
    return true;
  }
  list.push({ address, block });
  instances.set(key, list);
  return true;
}

function load() {
  if (loaded) return;
  loaded = true;
  try {
    for (const line of readFileSync(file(), "utf8").split("\n")) {
      if (!line) continue;
      const { key, address, block } = JSON.parse(line);
      add(key, address, block);
    }
  } catch {
    // none saved yet
  }
}

/**
 * A template instance and the block it was created in, which its block
 * handlers run from. envio keeps the address of a created data source and not
 * the block graph-node starts its triggers at, so the block is kept here, in
 * the project's `.envio` directory too: a restart loads the addresses from
 * storage and no register pass runs for the old creations.
 */
export function rememberInstance(chainId: number, template: string, address: string, block: number) {
  load();
  const key = keyOf(chainId, template);
  const lower = address.toLowerCase();
  if (!add(key, lower, block)) return;
  try {
    mkdirSync(path.dirname(file()), { recursive: true });
    appendFileSync(file(), JSON.stringify({ key, address: lower, block }) + "\n");
  } catch {
    // in memory still serves this run
  }
}

/** The instances of `template` created at or before `block`, with their creation blocks. */
export function instancesAt(chainId: number, template: string, block: number): Instance[] {
  load();
  return (instances.get(keyOf(chainId, template)) ?? []).filter((instance) => instance.block <= block);
}

export function forgetInstances() {
  instances.clear();
  loaded = false;
}
