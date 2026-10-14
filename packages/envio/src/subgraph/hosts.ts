/**
 * The graph-node host ops that reach outside the chain data envio already has:
 * IPFS, Arweave, ENS, `eth_getBalance`/`eth_getCode`, and a block handler's
 * timestamp. Each is an envio effect, so preload batches and dedupes them and
 * the sync bridge suspends the mapping until the answer lands.
 */

import { gate, rpcClient } from "./rpc.ts";
import * as Sury from "rescript-schema";
import { createEffect } from "../Envio.res.mjs";
import { configureBlockTimestamps, requestBlockTimestamp } from "./blocks.ts";
import { missingRpcMessage } from "./errors.ts";
import { HttpStatusError, untilAnswered } from "./transient.ts";
import { warn } from "../Logging.res.mjs";

const IPFS_GATEWAY = "https://ipfs.io/ipfs/";
const ARWEAVE_GATEWAY = "https://arweave.net/";
/** graph-node heals a hash from its rainbow table; this is the public one. */
const ENS_RAINBOW = "https://api.ensrainbow.io/v1/heal/";
const ENS_RAINBOW_ENV = "ENVIO_SUBGRAPH_ENS_RAINBOW_URL";
/** Lookups in flight at once: a registry backfill asks a million of them. */
const ENS_IN_FLIGHT = 32;
/** Attempts before a failing ENSRainbow is taken for down. */
const ENS_TRIES = 5;
/** How long a down ENSRainbow is answered for without being asked. */
const ENS_DOWN_MS = 5 * 60_000;

/** The heal endpoint a hash is appended to; `null` when lookups are turned off. */
function ensRainbowUrl(): string | null {
  const configured = process.env[ENS_RAINBOW_ENV]?.trim();
  if (configured === undefined) return ENS_RAINBOW;
  if (configured === "" || configured === "off") return null;
  return configured.endsWith("/") ? configured : `${configured}/`;
}

/** ENSRainbow's own "not in my table", as opposed to a host answering 404 for an app it no longer runs. */
async function isLabelNotFound(response: Response): Promise<boolean> {
  try {
    const body = (await response.json()) as { errorCode?: unknown; error?: unknown };
    return body.errorCode === 404 || typeof body.error === "string";
  } catch {
    return false;
  }
}

class RainbowDown extends Error {}

/**
 * A failure no retry can mend: the host's certificate isn't its own (Railway
 * serves api.ensrainbow.io's name with its own certificate), or it doesn't
 * resolve at all.
 */
const PERMANENT_FETCH_CODES = new Set([
  "ERR_TLS_CERT_ALTNAME_INVALID",
  "CERT_HAS_EXPIRED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "SELF_SIGNED_CERT_IN_CHAIN",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
  "ENOTFOUND",
]);

async function fetchRainbow(url: string, signal: AbortSignal): Promise<Response> {
  try {
    return await fetch(url, { signal });
  } catch (error) {
    const code = (error as { cause?: { code?: unknown } })?.cause?.code;
    if (typeof code === "string" && PERMANENT_FETCH_CODES.has(code)) {
      const detail = (error as { cause?: { message?: unknown } }).cause?.message;
      throw new RainbowDown(`${code}: ${String(detail ?? "")}`.trim());
    }
    throw error;
  }
}

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

  // graph-node returns null when its rainbow table doesn't hold the hash, and
  // for every hash when it has no table loaded. ENSRainbow answers the first
  // as a 404, and a hash that isn't one as a 400. A service that keeps failing
  // — no hosted ENSRainbow has stayed up — answers like graph-node without a
  // table, said once and not cached, rather than failing or stalling the run.
  const ensGate = gate(ENS_IN_FLIGHT);
  // Keyed by endpoint: the env var is read per lookup.
  const ensDownUntil = new Map<string, number>();
  const ensWarned = new Set<string>();
  const ensDown = (url: string, reason: string) => {
    ensDownUntil.set(url, Date.now() + ENS_DOWN_MS);
    if (ensWarned.has(url)) return;
    ensWarned.add(url);
    warn(
      `Envio Subgraph: ENSRainbow at ${url} isn't answering (${reason}), so ens.nameByHash() ` +
        "returns null, as graph-node does without a rainbow table, and asks again in " +
        `${ENS_DOWN_MS / 60_000} minutes. Those nulls aren't cached. Point ${ENS_RAINBOW_ENV} ` +
        "at a working ENSRainbow heal endpoint (…/v1/heal/), or set it to \"off\" to skip lookups.",
    );
  };
  const ensName = createEffect(
    {
      name: "envio_subgraph_ens_name",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input, context }: { input: string; context: { cache: boolean } }) => {
      const base = ensRainbowUrl();
      if (base === null || Date.now() < (ensDownUntil.get(base) ?? 0)) {
        context.cache = false;
        return null;
      }
      const url = base + input;
      try {
        return await untilAnswered(
          `the lookup of ${url}`,
          (signal) =>
            ensGate(async () => {
              // Lookups already backing off when another found it down stop here.
              if (Date.now() < (ensDownUntil.get(base) ?? 0)) throw new RainbowDown("already found down");
              const response = await fetchRainbow(url, signal);
              if (response.status === 400) return null;
              if (response.status === 404) {
                if (await isLabelNotFound(response)) return null;
                throw new RainbowDown(`${url} answered 404 without ENSRainbow's "Label not found"`);
              }
              if (!response.ok) {
                throw new HttpStatusError(url, response.status, response.statusText);
              }
              const body = (await response.json()) as { label?: string };
              return body.label ?? null;
            }),
          { maxTries: ENS_TRIES },
        );
      } catch (error) {
        const reason = error instanceof Error ? error.message.split("\n")[0] : String(error);
        ensDown(base, reason);
        context.cache = false;
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
