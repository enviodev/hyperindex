/**
 * The graph-node host ops that reach outside the chain data envio already has:
 * IPFS, Arweave, ENS, `eth_getBalance`/`eth_getCode`, and a block handler's
 * timestamp. Each is an envio effect, so preload batches and dedupes them and
 * the sync bridge suspends the mapping until the answer lands.
 */

import { rpcClient } from "./rpc.ts";
import * as Sury from "rescript-schema";
import { createEffect } from "../Envio.res.mjs";
import { configureBlockTimestamps, requestBlockTimestamp } from "./blocks.ts";
import { missingRpcMessage } from "./errors.ts";
import { HttpStatusError, untilAnswered } from "./transient.ts";

const IPFS_GATEWAY = "https://ipfs.io/ipfs/";
const ARWEAVE_GATEWAY = "https://arweave.net/";
/** graph-node heals a hash from its rainbow table; this is the public one. */
const ENS_RAINBOW = "https://api.ensrainbow.io/v1/heal/";

const nullableString = Sury.union([Sury.string, null]);

/**
 * Only "the gateway doesn't have it" is an answer, and a cached one; a timeout,
 * a 5xx or a rate limit is asked again rather than cached as a null for good.
 */
function fetchBase64(url: string): Promise<string | null> {
  return untilAnswered(`the fetch of ${url}`, async (signal) => {
    const response = await fetch(url, { signal });
    if (response.status === 404) {
      return null;
    }
    if (!response.ok) {
      throw new HttpStatusError(url, response.status, response.statusText);
    }
    const buffer = new Uint8Array(await response.arrayBuffer());
    return Buffer.from(buffer).toString("base64");
  });
}

export type HostEffects = ReturnType<typeof makeHostEffects>;

export function makeHostEffects(rpcUrls: string[]) {
  configureBlockTimestamps(rpcUrls);

  const clientOrThrow = (callSite: string) => {
    if (rpcUrls.length === 0) {
      throw new Error(missingRpcMessage(callSite));
    }
    return rpcClient(rpcUrls);
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

  // graph-node returns null when its rainbow table doesn't hold the hash.
  // ENSRainbow answers that as a 404, and a hash that isn't one as a 400;
  // anything else is the service failing, which must not be cached as a miss.
  const ensName = createEffect(
    {
      name: "envio_subgraph_ens_name",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => {
      const url = ENS_RAINBOW + input;
      return untilAnswered(`the lookup of ${url}`, async (signal) => {
        const response = await fetch(url, { signal });
        if (response.status === 404 || response.status === 400) {
          return null;
        }
        if (!response.ok) {
          throw new HttpStatusError(url, response.status, response.statusText);
        }
        const body = (await response.json()) as { label?: string };
        return body.label ?? null;
      });
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
      const client = clientOrThrow("ethereum.getBalance");
      const balance = await untilAnswered(`the balance of ${address} at block ${blockNumber}`, () =>
        client.getBalance({ address, blockNumber: BigInt(blockNumber) }),
      );
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
      const client = clientOrThrow("ethereum.hasCode");
      const code = await untilAnswered(`the code of ${address} at block ${blockNumber}`, () =>
        client.getCode({ address, blockNumber: BigInt(blockNumber) }),
      );
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
    async ({ input, context }: { input: number; context: { chain: { id: number } } }) => {
      const timestamp = await requestBlockTimestamp(context.chain.id, input);
      return timestamp.toString();
    },
  );

  return { ipfsCat, arweaveData, ensName, getBalance, hasCode, blockTimestamp };
}
