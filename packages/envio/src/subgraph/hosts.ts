/**
 * The graph-node host ops that reach outside the chain data envio already has:
 * IPFS, Arweave, ENS, `eth_getBalance`/`eth_getCode`, and a block handler's
 * timestamp. Each is an envio effect, so preload batches and dedupes them and
 * the sync bridge suspends the mapping until the answer lands.
 */

import { gate, rpcClient } from "./rpc.ts";
import * as Sury from "rescript-schema";
import { createEffect } from "../Envio.res.mjs";
import { configureBlockTimestamps, requestBlockHeader, requestBlockTimestamp } from "./blocks.ts";
import { configureReceiptLogs, requestReceiptLogs } from "./receipts.ts";
import { missingRpcMessage } from "./errors.ts";
import { HttpStatusError, isTransient, untilAnswered, withDeadline } from "./transient.ts";
import { warn } from "../Logging.res.mjs";

/**
 * Public IPFS gateways, in the order they are asked. The Graph's own node holds
 * what subgraphs pin and doesn't rate-limit a backfill the way ipfs.io does
 * (which answers 429 to a box that has made a handful of requests); the others
 * take over when it is down, rate-limited or doesn't have the file.
 */
const IPFS_GATEWAYS = ["https://ipfs.thegraph.com/ipfs/", "https://ipfs.io/ipfs/", "https://gateway.pinata.cloud/ipfs/"];
const IPFS_GATEWAY_ENV = "ENVIO_SUBGRAPH_IPFS_URL";
const ARWEAVE_GATEWAYS = ["https://arweave.net/"];
const ARWEAVE_GATEWAY_ENV = "ENVIO_SUBGRAPH_ARWEAVE_URL";
/** Fetches of a file data source's file in flight at once. */
const FILE_IN_FLIGHT = 16;

function gatewayList(env: string, fallback: string[], suffix: string): string[] {
  const configured = (process.env[env] ?? "")
    .split(/[\s,]+/)
    .map((url) => url.trim())
    .filter((url) => url !== "");
  if (configured.length === 0) return fallback;
  return configured.map((url) => {
    const base = url.replace(/\/+$/, "");
    return suffix && !base.endsWith(suffix) ? `${base}/${suffix}/` : `${base}/`;
  });
}

/**
 * The gateways a CID is appended to, read per fetch. `ENVIO_SUBGRAPH_IPFS_URL`
 * names one or several (comma separated), each with or without its `/ipfs/`
 * path.
 */
export function ipfsGatewayUrls(): string[] {
  return gatewayList(IPFS_GATEWAY_ENV, IPFS_GATEWAYS, "ipfs");
}

export function arweaveGatewayUrls(): string[] {
  return gatewayList(ARWEAVE_GATEWAY_ENV, ARWEAVE_GATEWAYS, "");
}

/**
 * graph-node's `ContentPath::new` (graph/src/ipfs/content_path.rs): a CID and
 * an optional path under it, as `<CID>[/<path>]`, `/ipfs/<CID>…`,
 * `ipfs://<CID>…`, or an http(s) URL with `/ipfs/<CID>…` in its path or the CID
 * in its `arg` query parameter. `null` for anything it refuses to parse, which
 * `ipfs.cat` answers with null and a file data source is ignored for.
 */
export function normalizeIpfsPath(raw: string): string | null {
  const input = raw.trim();
  if (input === "") return null;
  if (/^https?:\/\//.test(input)) {
    let url: URL;
    try {
      url = new URL(input);
    } catch {
      return null;
    }
    const arg = url.searchParams.get("arg");
    if (arg !== null) return cidAndPath(arg);
    const at = url.pathname.indexOf("/ipfs/");
    return cidAndPath(at >= 0 ? url.pathname.slice(at + "/ipfs/".length) : url.pathname);
  }
  return cidAndPath(input);
}

function cidAndPath(raw: string): string | null {
  let input = raw.replace(/^\/+|\/+$/g, "");
  for (const prefix of ["ipfs/", "ipfs://"]) {
    if (input.startsWith(prefix)) input = input.slice(prefix.length);
  }
  const slash = input.indexOf("/");
  const root = slash < 0 ? input : input.slice(0, slash);
  if (slash >= 0 && input.includes("?", slash)) return null;
  // CIDv0 is 46 base58 characters; CIDv1 is multibase-prefixed, most often
  // base32 (`b`) or base36 (`k`).
  const v0 = /^Qm[1-9A-HJ-NP-Za-km-z]{44}$/;
  const v1 = /^(b[a-z2-7]{20,}|k[a-z0-9]{20,}|z[1-9A-HJ-NP-Za-km-z]{20,}|f[0-9a-f]{20,})$/;
  return v0.test(root) || v1.test(root) ? input.replace(/\/+$/, "") : null;
}
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
 * One try at one URL: the bytes, `null` for the gateway's 404, a throw for
 * anything else (a timeout, a 5xx, a rate limit).
 */
async function fetchOnce(url: string, signal: AbortSignal): Promise<string | null> {
  const response = await fetch(url, { signal });
  if (response.status === 404) return null;
  if (!response.ok) throw new HttpStatusError(url, response.status, response.statusText);
  return Buffer.from(new Uint8Array(await response.arrayBuffer())).toString("base64");
}

/**
 * The file at `path` under each gateway in turn: the first to have it answers.
 * Only "none of them has it" is an answer, and a cached one; a timeout, a 5xx or
 * a rate limit at any gateway that didn't have it is asked again rather than
 * cached as a null for good. With `budgetMs`, the last failure is thrown once
 * asking again would end past that long after the first round.
 */
function fetchBase64(gateways: string[], path: string, budgetMs = Infinity): Promise<string | null> {
  return untilAnswered(`the fetch of ${path}`, () => firstGatewayAnswer(gateways, path), {
    deadline: false,
    budgetMs,
  });
}

/** How long a gateway has to answer before the next one is asked as well. */
const HEDGE_MS = 2_000;

/**
 * The gateways in order, each asked once the one before it has failed, has
 * no such file, or has kept silent for `HEDGE_MS`: a gateway that hangs to
 * its deadline holds the file up by `HEDGE_MS` rather than by the deadline.
 * The first to hand the file over answers and the others are cancelled; a
 * file is missing only if every gateway says so.
 */
function firstGatewayAnswer(gateways: string[], path: string): Promise<string | null> {
  if (gateways.length === 0) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const cancels: AbortController[] = [];
    let hedge: ReturnType<typeof setTimeout> | undefined;
    let started = 0;
    let finished = 0;
    let failure: unknown;
    let settled = false;
    const settle = (finish: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(hedge);
      for (const cancel of cancels) cancel.abort();
      finish();
    };
    const next = () => {
      clearTimeout(hedge);
      if (settled || started >= gateways.length) return;
      const url = gateways[started++] + path;
      const cancel = new AbortController();
      cancels.push(cancel);
      withDeadline(`the fetch of ${url}`, (signal) => fetchOnce(url, AbortSignal.any([signal, cancel.signal])))
        .then(
          (content) => {
            if (content !== null) settle(() => resolve(content));
          },
          (error) => {
            failure = error;
          },
        )
        .finally(() => {
          finished++;
          if (finished === gateways.length) {
            settle(() => (failure === undefined ? resolve(null) : reject(failure)));
          } else if (finished === started) {
            next();
          }
        });
      if (started < gateways.length) hedge = setTimeout(next, HEDGE_MS);
    };
    next();
  });
}

/** graph-node's `GRAPH_IPFS_TIMEOUT`, 60 s by default (graph/src/env/mappings.rs). */
function ipfsTimeoutMs(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS);
  return Number.isFinite(value) && value > 0 ? value : 60_000;
}

/** At most `limit` of `task`s run at once; the rest queue. */
function limiter(limit: number) {
  let running = 0;
  const waiting: (() => void)[] = [];
  return async <T>(task: () => Promise<T>): Promise<T> => {
    if (running < limit) running++;
    else await new Promise<void>((resolve) => waiting.push(resolve));
    try {
      return await task();
    } finally {
      const next = waiting.shift();
      if (next) next();
      else running--;
    }
  };
}

/** Tries before a file data source's file is given up on. */
function fileAttempts(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_FILE_ATTEMPTS);
  return Number.isInteger(value) && value > 0 ? value : 4;
}

function fileRetryMs(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_FILE_RETRY_MS);
  return Number.isFinite(value) && value >= 0 ? value : 2_000;
}

export type HostEffects = ReturnType<typeof makeHostEffects>;

export function makeHostEffects(
  rpcUrls: string[],
  headerLag: Record<number, number> = {},
  rpcOnlyChains: number[] = [],
) {
  configureBlockTimestamps(rpcUrls, headerLag, rpcOnlyChains);
  configureReceiptLogs(rpcUrls, rpcOnlyChains);

  const clientOrThrow = (callSite: string) => {
    if (rpcUrls.length === 0) {
      throw new Error(missingRpcMessage(callSite));
    }
    return rpcClient(rpcUrls);
  };

  // graph-node's `ipfs.cat` returns null for a file no gateway handed over
  // within its timeout ("Failed ipfs.cat, returning `null`"); that null isn't
  // cached, so a later ask fetches anew.
  const ipfsCat = createEffect(
    {
      name: "envio_subgraph_ipfs_cat",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input, context }: { input: string; context: { cache: boolean } }) => {
      const budget = ipfsTimeoutMs();
      try {
        return await fetchBase64(ipfsGatewayUrls(), input, budget);
      } catch (error) {
        if (!isTransient(error)) throw error;
        context.cache = false;
        const reason = error instanceof Error ? error.message.split("\n")[0] : String(error);
        warn(
          `Envio Subgraph: ipfs.cat(${input}) got no answer within ${budget}ms (${reason}), so it returns null, ` +
            "as graph-node's does after GRAPH_IPFS_TIMEOUT. The null isn't cached; ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS " +
            "sets the wait, ENVIO_SUBGRAPH_IPFS_URL the gateways.",
        );
        return null;
      }
    },
  );

  // `ipfs.map` fails its handler where `ipfs.cat` would answer null, and
  // graph-node retries a block that failed that way, so it waits for the file.
  const ipfsMapFile = createEffect(
    {
      name: "envio_subgraph_ipfs_map",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => fetchBase64(ipfsGatewayUrls(), input),
  );

  const arweaveData = createEffect(
    {
      name: "envio_subgraph_arweave",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input }: { input: string }) => fetchBase64(arweaveGatewayUrls(), input),
  );

  // A file data source's file: `ipfs:<path>` or `arweave:<id>`. graph-node polls
  // for it until it exists, backing off after a miss and after an error alike
  // (core/src/polling_monitor/mod.rs). Here a file every gateway says isn't
  // there is asked for `fileAttempts()` times and then reads null, cached like
  // any answer, and the handler is skipped. A failure asking again can mend (a
  // 429, a 5xx, a timeout) is no such answer: it is asked again, with backoff,
  // for the `ipfs.cat` budget, and a file still out of reach after that reads
  // null uncached, so a later run (or the same file created again) asks anew.
  const fileGate = limiter(FILE_IN_FLIGHT);
  const fileData = createEffect(
    {
      name: "envio_subgraph_file",
      input: Sury.string,
      output: nullableString,
      rateLimit: false,
      cache: true,
    },
    async ({ input, context }: { input: string; context: { cache: boolean } }) => {
      const split = input.indexOf(":");
      const kind = input.slice(0, split);
      const id = input.slice(split + 1);
      const gateways = kind === "arweave" ? arweaveGatewayUrls() : ipfsGatewayUrls();
      const url = gateways[0] + id;
      const attempts = fileAttempts();
      const budget = ipfsTimeoutMs();
      const started = Date.now();
      let unreachable = false;
      for (let attempt = 1; attempt <= attempts; attempt++) {
        try {
          const content = await untilAnswered(`the fetch of ${url}`, () => fileGate(() => firstGatewayAnswer(gateways, id)), {
            deadline: false,
            budgetMs: Math.max(0, budget - (Date.now() - started)),
          });
          if (content !== null) return content;
          unreachable = false;
        } catch (error) {
          const reason = error instanceof Error ? error.message.split("\n")[0] : String(error);
          if (isTransient(error)) {
            warn(
              `Envio Subgraph: the file data source's file ${url} couldn't be fetched within ${budget}ms (${reason}); ` +
                "its handler is skipped. The miss isn't cached; ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS sets the wait.",
            );
            context.cache = false;
            return null;
          }
          unreachable = true;
          warn(`Envio Subgraph: file ${url} failed (${reason}).`);
        }
        if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, fileRetryMs() * 2 ** (attempt - 1)));
      }
      warn(
        `Envio Subgraph: the file data source's file ${url} wasn't there after ${attempts} attempts; ` +
          "its handler is skipped. (graph-node keeps polling for it; set ENVIO_SUBGRAPH_FILE_ATTEMPTS to wait longer.)",
      );
      if (unreachable) context.cache = false;
      return null;
    },
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
          { maxTries: ENS_TRIES, deadline: false },
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
      const balance = await untilAnswered(
        `the balance of ${address} at block ${blockNumber}`,
        () => client.getBalance({ address, blockNumber: BigInt(blockNumber) }),
        { deadline: false },
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
      const code = await untilAnswered(
        `the code of ${address} at block ${blockNumber}`,
        () => client.getCode({ address, blockNumber: BigInt(blockNumber) }),
        { deadline: false },
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

  // A block handler's `block.hash` and the rest of the header, as one JSON
  // object. Uncached for the same reason as the timestamp.
  const blockHeader = createEffect(
    {
      name: "envio_subgraph_block_header",
      input: Sury.number,
      output: Sury.string,
      rateLimit: false,
      cache: false,
      crossChain: false,
    },
    async ({ input, context }: { input: number; context: { chain: { id: number } } }) =>
      JSON.stringify(await requestBlockHeader(context.chain.id, input)),
  );

  // `event.receipt.logs`: the logs of one transaction, as a JSON array. Input
  // is `{ blockNumber, transactionIndex, transactionHash }`.
  const receiptLogs = createEffect(
    {
      name: "envio_subgraph_receipt_logs",
      input: Sury.string,
      output: Sury.string,
      rateLimit: false,
      cache: false,
      crossChain: false,
    },
    async ({ input, context }: { input: string; context: { chain: { id: number } } }) =>
      JSON.stringify(await requestReceiptLogs({ ...JSON.parse(input), chainId: context.chain.id })),
  );

  return { ipfsCat, ipfsMapFile, arweaveData, fileData, ensName, getBalance, hasCode, blockTimestamp, blockHeader, receiptLogs };
}
