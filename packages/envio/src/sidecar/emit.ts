import * as S from "rescript-schema";
import type { SidecarContract, SidecarWebhookBody } from "./contract.js";
import type { SidecarLogger } from "./log.js";

export type EmitOptions = {
  /** Which chain the indexer applies the webhook on. Filled from the originating
   * call inside a function; required on multichain indexers elsewhere. */
  readonly chainId?: number;
  /** Dedupe key; inside a function defaults to `<callId>#<n>`. */
  readonly idempotencyKey?: string;
};

export type EmitResult = {
  readonly id: string;
  readonly chainId: number | undefined;
};

export type Emit<C extends SidecarContract> = {
  readonly [K in keyof C["webhooks"]]: (body: SidecarWebhookBody<C, K>, opts?: EmitOptions) => Promise<EmitResult>;
} & {
  /** A webhook outside the contract: `body` must already be JSON. */
  readonly raw: (name: string, body: unknown, opts?: EmitOptions) => Promise<EmitResult>;
};

export class SidecarEmitError extends Error {
  override readonly name = "SidecarEmitError";
  readonly webhook: string;
  readonly status: number | undefined;
  readonly detail: unknown;
  constructor(webhook: string, message: string, options: { status?: number; detail?: unknown; cause?: unknown } = {}) {
    super(`Webhook '${webhook}': ${message}`, options.cause === undefined ? undefined : { cause: options.cause });
    this.webhook = webhook;
    this.status = options.status;
    this.detail = options.detail;
  }
}

export type RetryPolicy = {
  /** How long a webhook keeps being retried before `emit` rejects. The runtime
   * fills it from `ENVIO_EMIT_RETRY_MAX_MS`. */
  readonly maxMs?: number;
  /** First backoff; it doubles per attempt up to `capMs`, with jitter. */
  readonly baseMs: number;
  readonly capMs: number;
  /** Optional cap on attempts on top of the time budget. */
  readonly attempts?: number;
};

/** wiki 09 sections 3 and 4: 250 ms doubling to 5 s, for up to 10 min. */
export const DEFAULT_RETRY: RetryPolicy & { readonly maxMs: number } = { maxMs: 600_000, baseMs: 250, capMs: 5_000 };

/** Why `emit` rejected: refused by the indexer (4xx), out of retry budget,
 * abandoned on timeout or shutdown, or a bad name or body (nothing sent). */
export type EmitFailure = "rejected" | "undeliverable" | "abandoned" | "invalid";

export type EmitTransport = {
  readonly indexerInternalUrl: string;
  readonly webhookSecret?: string | undefined;
  readonly fetch?: typeof fetch;
  readonly retry?: RetryPolicy;
  readonly timeoutMs?: number;
  readonly log: SidecarLogger;
  readonly onSent?: (webhook: string) => void;
  readonly onFailed?: (webhook: string, outcome: EmitFailure) => void;
  /** Called before each retry wait. */
  readonly onRetry?: (webhook: string) => void;
  /** Handed every delivery in progress, so shutdown can wait for retries. */
  readonly onPending?: (sending: Promise<unknown>) => void;
  /** Aborted when the sidecar stops waiting for deliveries (grace period over). */
  readonly signal?: AbortSignal;
};

export type EmitBinding = {
  readonly chainId?: number;
  readonly callId?: string;
  /** Aborted when the function that owns this emitter times out: later sends
   * and pending retries reject instead of delivering a stale result. */
  readonly signal?: AbortSignal;
};

const WEBHOOK_NAME = /^[A-Za-z_][A-Za-z0-9_.-]*$/;

const sleep = (ms: number, signals: readonly AbortSignal[]) =>
  new Promise<void>((resolve) => {
    const done = () => {
      clearTimeout(timer);
      for (const signal of signals) signal.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    for (const signal of signals) signal.addEventListener("abort", done, { once: true });
  });

/** `retry-after` as delta seconds or an HTTP date, in ms. */
const retryAfterMs = (response: Response): number | undefined => {
  const raw = response.headers.get("retry-after");
  if (raw === null || raw.trim() === "") return undefined;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1_000;
  const at = Date.parse(raw);
  return Number.isNaN(at) ? undefined : Math.max(0, at - Date.now());
};

const readJson = async (response: Response): Promise<unknown> => {
  const text = await response.text();
  if (text === "") return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

export function createEmit<C extends SidecarContract>(
  contract: C,
  transport: EmitTransport,
  binding: EmitBinding = {},
): Emit<C> {
  const doFetch = transport.fetch ?? fetch;
  const retry: RetryPolicy = transport.retry ?? DEFAULT_RETRY;
  const maxMs = retry.maxMs ?? DEFAULT_RETRY.maxMs;
  const timeoutMs = transport.timeoutMs ?? 5_000;
  const signals = [binding.signal, transport.signal].filter((signal) => signal !== undefined);
  let seq = 0;

  const abandoned = (name: string): SidecarEmitError | undefined => {
    const signal = signals.find((candidate) => candidate.aborted);
    if (signal === undefined) return undefined;
    const reason: unknown = signal.reason;
    return new SidecarEmitError(name, `abandoned: ${reason instanceof Error ? reason.message : String(reason)}`, {
      cause: reason,
    });
  };

  const send = async (name: string, json: unknown, opts: EmitOptions): Promise<EmitResult> => {
    if (!WEBHOOK_NAME.test(name) || name.startsWith("sidecar.")) {
      transport.onFailed?.(name, "invalid");
      throw new SidecarEmitError(name, "invalid webhook name");
    }
    const early = abandoned(name);
    if (early !== undefined) {
      transport.onFailed?.(name, "abandoned");
      throw early;
    }
    let payload: string;
    try {
      payload = JSON.stringify(json);
    } catch (cause) {
      transport.onFailed?.(name, "invalid");
      throw new SidecarEmitError(name, "body is not JSON serialisable (use the contract schema for bigint)", { cause });
    }
    const chainId = opts.chainId ?? binding.chainId;
    const idempotencyKey =
      opts.idempotencyKey ?? (binding.callId === undefined ? undefined : `${binding.callId}#${seq++}`);
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (chainId !== undefined) headers["x-envio-chain-id"] = String(chainId);
    if (idempotencyKey !== undefined) headers["idempotency-key"] = idempotencyKey;
    if (transport.webhookSecret !== undefined) headers["x-envio-webhook-secret"] = transport.webhookSecret;
    const url = `${transport.indexerInternalUrl}/webhooks/${name}`;

    const startedAt = Date.now();
    const deadline = startedAt + maxMs;
    let lastFailure = "no attempt made";
    let attempt = 0;
    for (;;) {
      attempt++;
      let wait: number | undefined;
      let response: Response | undefined;
      try {
        response = await doFetch(url, {
          method: "POST",
          headers,
          body: payload,
          signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), ...signals]),
        });
      } catch (error) {
        lastFailure = error instanceof Error ? error.message : String(error);
      }
      if (response?.ok === true) {
        const body = await readJson(response);
        transport.onSent?.(name);
        const result =
          typeof body === "object" && body !== null
            ? (body as { id?: unknown; chainId?: unknown })
            : {};
        return {
          id: typeof result.id === "string" ? result.id : "",
          chainId: typeof result.chainId === "number" ? result.chainId : chainId,
        };
      }
      if (response !== undefined) {
        const detail = await readJson(response);
        // 4xx (other than 429) means the indexer understood and refused: a schema
        // or chain problem that a retry cannot fix.
        if (response.status < 500 && response.status !== 429) {
          transport.onFailed?.(name, "rejected");
          throw new SidecarEmitError(name, `indexer rejected it (${response.status})`, {
            status: response.status,
            detail,
          });
        }
        lastFailure = `status ${response.status}`;
        if (response.status === 503 || response.status === 429) wait = retryAfterMs(response);
      }
      const stop = abandoned(name);
      if (stop !== undefined) {
        transport.onFailed?.(name, "abandoned");
        throw stop;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0 || (retry.attempts !== undefined && attempt >= retry.attempts)) break;
      if (wait === undefined) {
        const backoff = Math.min(retry.capMs, retry.baseMs * 2 ** (attempt - 1));
        wait = backoff / 2 + Math.random() * (backoff / 2);
      }
      // The last wait is cut to the deadline, so one final attempt lands on it.
      const delay = Math.min(wait, remaining);
      transport.log.warn("webhook delivery failed, retrying", { webhook: name, attempt, delay, reason: lastFailure });
      transport.onRetry?.(name);
      await sleep(delay, signals);
      const aborted = abandoned(name);
      if (aborted !== undefined) {
        transport.onFailed?.(name, "abandoned");
        throw aborted;
      }
    }
    transport.onFailed?.(name, "undeliverable");
    throw new SidecarEmitError(
      name,
      `undeliverable after ${attempt} attempts in ${Date.now() - startedAt} ms: ${lastFailure}`,
    );
  };

  const track = (sending: Promise<EmitResult>): Promise<EmitResult> => {
    transport.onPending?.(sending);
    return sending;
  };

  const emit: Record<string, unknown> = {
    raw: (name: string, body: unknown, opts: EmitOptions = {}) => track(send(name, body, opts)),
  };
  for (const [name, def] of Object.entries(contract.webhooks as Record<string, { body: S.Schema<unknown> }>)) {
    emit[name] = (body: unknown, opts: EmitOptions = {}) => {
      let json: unknown;
      try {
        json = S.reverseConvertToJsonOrThrow(body, def.body);
        // Converting does not type-check (`{ at: "soon" }` converts fine), so the
        // JSON is parsed back the way the indexer will parse it.
        S.parseOrThrow(json, def.body);
      } catch (cause) {
        transport.onFailed?.(name, "invalid");
        return Promise.reject(
          new SidecarEmitError(name, `body does not match the contract: ${cause instanceof Error ? cause.message : String(cause)}`, {
            cause,
          }),
        );
      }
      return track(send(name, json, opts));
    };
  }
  return emit as Emit<C>;
}
