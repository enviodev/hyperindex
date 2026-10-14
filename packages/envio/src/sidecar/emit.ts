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
  readonly attempts: number;
  readonly baseMs: number;
  readonly capMs: number;
};

export const DEFAULT_RETRY: RetryPolicy = { attempts: 8, baseMs: 200, capMs: 5_000 };

export type EmitTransport = {
  readonly indexerInternalUrl: string;
  readonly webhookSecret?: string | undefined;
  readonly fetch?: typeof fetch;
  readonly retry?: RetryPolicy;
  readonly timeoutMs?: number;
  readonly log: SidecarLogger;
  readonly onSent?: () => void;
  readonly onFailed?: () => void;
  /** Handed every delivery in progress, so shutdown can wait for retries. */
  readonly onPending?: (sending: Promise<unknown>) => void;
};

export type EmitBinding = {
  readonly chainId?: number;
  readonly callId?: string;
};

const WEBHOOK_NAME = /^[A-Za-z_][A-Za-z0-9_.-]*$/;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

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
  const retry = transport.retry ?? DEFAULT_RETRY;
  const timeoutMs = transport.timeoutMs ?? 5_000;
  let seq = 0;

  const send = async (name: string, json: unknown, opts: EmitOptions): Promise<EmitResult> => {
    if (!WEBHOOK_NAME.test(name) || name.startsWith("sidecar.")) {
      throw new SidecarEmitError(name, "invalid webhook name");
    }
    let payload: string;
    try {
      payload = JSON.stringify(json);
    } catch (cause) {
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

    let lastFailure: string = "no attempt made";
    for (let attempt = 0; attempt < retry.attempts; attempt++) {
      if (attempt > 0) {
        const delay = Math.min(retry.capMs, retry.baseMs * 2 ** (attempt - 1));
        transport.log.warn("webhook delivery failed, retrying", { webhook: name, attempt, delay, reason: lastFailure });
        await sleep(delay);
      }
      let response: Response;
      try {
        response = await doFetch(url, {
          method: "POST",
          headers,
          body: payload,
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (error) {
        lastFailure = error instanceof Error ? error.message : String(error);
        continue;
      }
      if (response.ok) {
        const body = await readJson(response);
        transport.onSent?.();
        const result =
          typeof body === "object" && body !== null
            ? (body as { id?: unknown; chainId?: unknown })
            : {};
        return {
          id: typeof result.id === "string" ? result.id : "",
          chainId: typeof result.chainId === "number" ? result.chainId : chainId,
        };
      }
      const detail = await readJson(response);
      // 4xx (other than 429) means the indexer understood and refused: a schema
      // or chain problem that a retry cannot fix.
      if (response.status < 500 && response.status !== 429) {
        transport.onFailed?.();
        throw new SidecarEmitError(name, `indexer rejected it (${response.status})`, {
          status: response.status,
          detail,
        });
      }
      lastFailure = `status ${response.status}`;
    }
    transport.onFailed?.();
    throw new SidecarEmitError(name, `undeliverable after ${retry.attempts} attempts: ${lastFailure}`);
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
