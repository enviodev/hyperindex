/**
 * The graph-node host ops that reach outside the chain data envio already has:
 * IPFS, Arweave, ENS, `eth_getBalance`/`eth_getCode`, and a block handler's
 * timestamp. Each is an envio effect, so preload batches and dedupes them and
 * the sync bridge suspends the mapping until the answer lands.
 */

import { createPublicClient, fallback, http } from "viem";
import * as Sury from "rescript-schema";
import { createEffect } from "../Envio.res.mjs";
import { missingRpcMessage } from "./errors.ts";

const IPFS_GATEWAY = "https://ipfs.io/ipfs/";
const ARWEAVE_GATEWAY = "https://arweave.net/";
/** graph-node heals a hash from its rainbow table; this is the public one. */
const ENS_RAINBOW = "https://api.ensrainbow.io/v1/heal/";

const nullableString = Sury.union([Sury.string, null]);

async function fetchBase64(url: string): Promise<string | null> {
  const response = await fetch(url);
  if (!response.ok) {
    return null;
  }
  const buffer = new Uint8Array(await response.arrayBuffer());
  return Buffer.from(buffer).toString("base64");
}

export type HostEffects = ReturnType<typeof makeHostEffects>;

export function makeHostEffects(rpcUrls: string[]) {
  let client: ReturnType<typeof createPublicClient> | null = null;
  const clientOrThrow = (callSite: string) => {
    if (rpcUrls.length === 0) {
      throw new Error(missingRpcMessage(callSite));
    }
    client ??= createPublicClient({
      transport: fallback(rpcUrls.map((url) => http(url, { retryCount: 0 }))),
    });
    return client;
  };

  const ipfsCat = createEffect(
    {
      name: "envio_subgraph_ipfs_cat",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => fetchBase64(IPFS_GATEWAY + input),
  );

  const arweaveData = createEffect(
    {
      name: "envio_subgraph_arweave",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => fetchBase64(ARWEAVE_GATEWAY + input),
  );

  // Best-effort, as graph-node is: it returns null when its rainbow table
  // doesn't hold the hash, so a lookup failure is a miss, not an error.
  const ensName = createEffect(
    {
      name: "envio_subgraph_ens_name",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => {
      try {
        const response = await fetch(ENS_RAINBOW + input);
        if (!response.ok) return null;
        const body = (await response.json()) as { label?: string };
        return body.label ?? null;
      } catch {
        return null;
      }
    },
  );

  const getBalance = createEffect(
    {
      name: "envio_subgraph_eth_balance",
      input: Sury.string,
      output: Sury.string,
      rateLimit: false,
      cache: true,
      crossChain: false,
    },
    async ({ input }: { input: string }) => {
      const { address, blockNumber } = JSON.parse(input);
      const balance = await clientOrThrow("ethereum.getBalance").getBalance({
        address,
        blockNumber: BigInt(blockNumber),
      });
      return balance.toString();
    },
  );

  const hasCode = createEffect(
    {
      name: "envio_subgraph_has_code",
      input: Sury.string,
      output: Sury.boolean,
      rateLimit: false,
      cache: true,
      crossChain: false,
    },
    async ({ input }: { input: string }) => {
      const { address, blockNumber } = JSON.parse(input);
      const code = await clientOrThrow("ethereum.hasCode").getCode({
        address,
        blockNumber: BigInt(blockNumber),
      });
      return code !== undefined && code !== "0x";
    },
  );

  // Uncached on purpose: a block's timestamp is read exactly once, by that
  // block's own handler invocation, so a persisted row per indexed block would
  // be bloat with no reuse. The in-memory memo still covers replay rounds and
  // the preload -> execute transition.
  const blockTimestamp = createEffect(
    {
      name: "envio_subgraph_block_timestamp",
      input: Sury.number,
      output: Sury.string,
      rateLimit: false,
      cache: false,
      crossChain: false,
    },
    async ({ input }: { input: number }) => {
      const block = await clientOrThrow("block.timestamp in a block handler").getBlock({
        blockNumber: BigInt(input),
      });
      return block.timestamp.toString();
    },
  );

  return { ipfsCat, arweaveData, ensName, getBalance, hasCode, blockTimestamp };
}
