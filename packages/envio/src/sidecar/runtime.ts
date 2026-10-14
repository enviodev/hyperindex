import express from "express";
import type { Server } from "node:http";
import * as S from "rescript-schema";
import { isSidecarContract, type SidecarContract, type SidecarFunctionInput } from "./contract.js";
import { createEmit, createEmitBreaker, DEFAULT_RETRY, type Emit, type EmitTransport, type RetryPolicy } from "./emit.js";
import { readEnv } from "./env.js";
import { createRootLogger, toUserLogger, type SidecarLogger } from "./log.js";
import { createIndexerClient, type EntityMetaInput, type IndexerClient } from "./client.js";
import { createMetricsRegistry, PROMETHEUS_CONTENT_TYPE } from "./metrics.js";

export type SidecarCall = {
  readonly id: string;
  readonly chainId: number;
  readonly blockNumber: number;
  /** Absent for block handler calls. */
  readonly blockTimestamp?: number;
  readonly batchId: string;
};

export type SidecarFunctionArgs<C extends SidecarContract, K extends keyof C["functions"]> = {
  readonly input: SidecarFunctionInput<C, K>;
  readonly call: SidecarCall;
  readonly emit: Emit<C>;
  readonly indexer: IndexerClient;
  readonly log: SidecarLogger;
  /** Aborted when the call times out. JavaScript cannot stop a running
   * function, so long work should check it (or pass it to `fetch`). */
  readonly signal: AbortSignal;
};

export type SidecarFunction<C extends SidecarContract, K extends keyof C["functions"]> = (
  args: SidecarFunctionArgs<C, K>,
) => Promise<void> | void;

export type SidecarFunctionImpl<C extends SidecarContract, K extends keyof C["functions"]> =
  | SidecarFunction<C, K>
  | {
      /** In-flight calls of this function at once. Default 1. */
      readonly concurrency?: number;
      /** Queued calls this function may hold before new ones are rejected. Default 10000. */
      readonly maxQueue?: number;
      /** Longest one call may run: ms or `"30s"`, `"5m"`. Default
       * `ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS` (60 s); 0 turns it off. A timed out
       * call is logged and counted as an error, not retried, and frees its slot. */
      readonly timeout?: string | number;
      readonly run: SidecarFunction<C, K>;
    };

export type SidecarJobArgs<C extends SidecarContract> = {
  readonly emit: Emit<C>;
  readonly indexer: IndexerClient;
  readonly log: SidecarLogger;
};

export type SidecarJob<C extends SidecarContract> = {
  /** `"30s"`, `"5m"`, `"1h"` or milliseconds. */
  readonly every: string | number;
  /** Also run once as soon as the sidecar is listening, instead of waiting a
   * full interval for the first run. Default false. */
  readonly runOnStart?: boolean;
  readonly run: (args: SidecarJobArgs<C>) => Promise<void> | void;
};

export type SidecarRoutesApp<C extends SidecarContract> = express.Express & {
  readonly indexer: IndexerClient;
  readonly emit: Emit<C>;
  readonly log: SidecarLogger;
};

export type RollbackNotice = { readonly chainId: number; readonly rollbackToBlock: number };

export type SidecarImpl<C extends SidecarContract> = {
  readonly functions: { readonly [K in keyof C["functions"]]: SidecarFunctionImpl<C, K> };
  readonly jobs?: Record<string, SidecarJob<C>>;
  readonly routes?: (app: SidecarRoutesApp<C>) => void;
  readonly onRollback?: (notice: RollbackNotice) => Promise<void> | void;
};

export type StartOptions = {
  readonly internalPort?: number;
  readonly publicPort?: number;
  readonly indexerInternalUrl?: string;
  readonly graphqlUrl?: string;
  /** Entity definitions (`Config.getPgUserEntities`) so reads decode bigint and
   * BigDecimal exactly; without them the client introspects the GraphQL schema. */
  readonly entities?: readonly EntityMetaInput[];
  readonly startJobs?: boolean;
  readonly env?: NodeJS.ProcessEnv;
  readonly logLevel?: string;
  readonly logDestination?: NodeJS.WritableStream;
  readonly fetch?: typeof fetch;
  /** Webhook backoff. `maxMs` defaults to `ENVIO_EMIT_RETRY_MAX_MS`, else 600000. */
  readonly retry?: RetryPolicy;
  /** Longest `close()` waits for running work. Default `ENVIO_SIDECAR_GRACE_MS`, else 20000. */
  readonly graceMs?: number;
  /** Default per-function timeout in ms. Default `ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS`, else 60000; 0 for none. */
  readonly functionTimeoutMs?: number;
  /** Accepted call ids remembered to dedupe redelivery. Default `ENVIO_SIDECAR_DEDUPE_MAX`, else 100000. */
  readonly dedupeMax?: number;
  /** Emit circuit breaker. Defaults `ENVIO_EMIT_BREAKER_FAILURES` (5, 0 = off) and
   * `ENVIO_EMIT_BREAKER_COOLDOWN_MS` (5000). */
  readonly emitBreaker?: { readonly failures?: number; readonly cooldownMs?: number };
};

export type CloseOptions = {
  /** Overrides the grace period given to `start`. */
  readonly graceMs?: number;
};

export type CloseReport = {
  /** False when the grace period ran out first. */
  readonly drained: boolean;
  readonly graceMs: number;
  /** What was still unfinished when the servers closed. */
  readonly abandoned: {
    readonly running: Readonly<Record<string, number>>;
    readonly queued: Readonly<Record<string, number>>;
    readonly emits: number;
    readonly jobs: number;
  };
};

export type SidecarStats = {
  readonly accepted: number;
  readonly rejected: number;
  readonly duplicates: number;
  readonly ran: number;
  readonly failed: number;
  /** Calls that ran past their timeout (not counted in `failed`). */
  readonly timedOut: number;
  readonly dropped: number;
  readonly queued: Readonly<Record<string, number>>;
  readonly webhooksSent: number;
  readonly webhooksFailed: number;
};

export type RunningSidecar = {
  readonly internalPort: number;
  readonly publicPort: number;
  /** Stops taking calls (503) and jobs, waits for running and queued functions,
   * jobs and webhook deliveries up to the grace period, then closes the servers.
   * Calling it again returns the same promise. */
  readonly close: (options?: CloseOptions) => Promise<CloseReport>;
  readonly stats: () => SidecarStats;
  /** Resolves once no call is queued or running. */
  readonly waitIdle: () => Promise<void>;
};

export type Sidecar<C extends SidecarContract> = SidecarImpl<C> & {
  readonly contract: C;
  readonly start: (options?: StartOptions) => Promise<RunningSidecar>;
};

type WireCall = {
  readonly id: string;
  readonly fn: string;
  readonly chainId: number;
  readonly blockNumber: number;
  readonly blockTimestamp?: number;
  readonly input: unknown;
};

type QueuedCall = { readonly call: SidecarCall; readonly fn: string; readonly input: unknown };

const DEFAULT_MAX_QUEUE = 10_000;

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const malformedCall = (raw: unknown): string | null => {
  if (!isPlainObject(raw)) return "call is not an object";
  if (typeof raw.id !== "string" || raw.id === "") return "`id` must be a non-empty string";
  if (typeof raw.fn !== "string" || raw.fn === "") return "`fn` must be a non-empty string";
  if (typeof raw.chainId !== "number") return "`chainId` must be a number";
  if (typeof raw.blockNumber !== "number") return "`blockNumber` must be a number";
  if (raw.blockTimestamp !== undefined && typeof raw.blockTimestamp !== "number") {
    return "`blockTimestamp` must be a number";
  }
  return null;
};

const parseDuration = (value: string | number): number | null => {
  if (typeof value === "number") return Number.isFinite(value) && value >= 0 ? value : null;
  const match = /^(\d+)(ms|s|m|h)$/.exec(value);
  if (match === null) return null;
  return Number(match[1]) * { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 }[match[2] as "ms" | "s" | "m" | "h"];
};

const parseTimeout = (name: string, timeout: string | number): number => {
  const ms = parseDuration(timeout);
  if (ms === null) {
    throw new Error(`createSidecar: function '${name}' timeout '${timeout}' is not like "30s", "5m" or a number of ms`);
  }
  return ms;
};

export const parseEvery = (every: string | number): number => {
  if (typeof every === "number") {
    if (!Number.isFinite(every) || every <= 0) throw new Error(`Job interval must be positive, got ${every}`);
    return every;
  }
  const match = /^(\d+)(ms|s|m|h)$/.exec(every);
  if (match === null) throw new Error(`Job interval '${every}' is not like "30s", "5m", "1h" or a number of ms`);
  const amount = Number(match[1]);
  const unit = { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 }[match[2] as "ms" | "s" | "m" | "h"];
  if (amount <= 0) throw new Error(`Job interval '${every}' must be positive`);
  return amount * unit;
};

const listen = (app: express.Express, port: number, host: string): Promise<Server> =>
  new Promise((resolve, reject) => {
    const server = app.listen(port, host);
    server.once("listening", () => resolve(server));
    server.once("error", reject);
  });

const closeServer = (server: Server): Promise<void> =>
  new Promise((resolve) => {
    server.closeAllConnections();
    server.close(() => resolve());
  });

const portOf = (server: Server): number => {
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("Server has no TCP port");
  return address.port;
};

type Handler = (...args: unknown[]) => unknown;

// Express 4 drops a rejected promise from a route on the floor, which in Node
// is a process crash. Routes users write are almost all async, so each one is
// wrapped to hand its rejection to the error middleware.
const wrapAsyncRoutes = (app: express.Express) => {
  for (const method of ["get", "post", "put", "patch", "delete", "all"] as const) {
    const original = (app[method] as unknown as Handler).bind(app);
    (app as unknown as Record<string, unknown>)[method] = (...args: unknown[]) => {
      if (args.length === 1 && method === "get") return original(...args);
      return original(
        ...args.map((arg) => {
          if (typeof arg !== "function" || arg.length >= 4) return arg;
          return (req: unknown, res: unknown, next: (error: unknown) => void) => {
            try {
              const result = (arg as Handler)(req, res, next);
              if (result instanceof Promise) result.catch(next);
            } catch (error) {
              next(error);
            }
          };
        }),
      );
    };
  }
};

export function createSidecar<C extends SidecarContract>(contract: C, impl: SidecarImpl<C>): Sidecar<C> {
  if (!isSidecarContract(contract)) {
    throw new Error("createSidecar: first argument must come from defineSidecar(...)");
  }
  if (!isPlainObject(impl) || !isPlainObject(impl.functions)) {
    throw new Error("createSidecar: second argument must be { functions: {...}, jobs?, routes?, onRollback? }");
  }
  const contractFunctions = contract.functions as Record<string, { input: S.Schema<unknown> }>;
  const functions = impl.functions as Record<string, SidecarFunctionImpl<C, keyof C["functions"]>>;
  for (const name of Object.keys(contractFunctions)) {
    const fn = functions[name];
    if (typeof fn !== "function" && !(isPlainObject(fn) && typeof fn.run === "function")) {
      throw new Error(`createSidecar: function '${name}' is in the contract but not implemented`);
    }
    if (typeof fn !== "function" && fn.timeout !== undefined) parseTimeout(name, fn.timeout);
  }
  for (const name of Object.keys(functions)) {
    if (!(name in contractFunctions)) {
      throw new Error(`createSidecar: function '${name}' is implemented but not in the contract`);
    }
  }
  const jobs = impl.jobs ?? {};
  for (const [name, job] of Object.entries(jobs)) {
    if (!isPlainObject(job) || typeof job.run !== "function") {
      throw new Error(`createSidecar: job '${name}' must be { every, run }`);
    }
    parseEvery(job.every);
    if (job.runOnStart !== undefined && typeof job.runOnStart !== "boolean") {
      throw new Error(`createSidecar: job '${name}' runOnStart must be true or false`);
    }
  }

  const start = async (options: StartOptions = {}): Promise<RunningSidecar> => {
    const env = readEnv(options.env ?? process.env);
    const rootLogger = createRootLogger({
      level: options.logLevel ?? env.logLevel,
      ...(options.logDestination === undefined ? {} : { destination: options.logDestination, pretty: false }),
    });
    const log = toUserLogger(rootLogger.child({ component: "sidecar" }));

    const counters = {
      accepted: 0,
      rejected: 0,
      duplicates: 0,
      ran: 0,
      failed: 0,
      timedOut: 0,
      dropped: 0,
      webhooksSent: 0,
      webhooksFailed: 0,
    };
    const pendingEmits = new Set<Promise<unknown>>();
    let runningJobs = 0;
    let closing = false;
    let ready = false;

    // Names stay clear of the indexer's own envio_sidecar_* series (calls_total,
    // queue_depth, up: the indexer's view of delivery), which mean something else.
    const metrics = createMetricsRegistry();
    const callsTotal = metrics.counter(
      "envio_sidecar_function_calls_total",
      "Calls by function and outcome (accepted, duplicate, rejected, succeeded, failed, timed_out).",
    );
    const durations = metrics.histogram(
      "envio_sidecar_function_duration_seconds",
      "Time a sidecar function call ran, up to its timeout.",
    );
    metrics.gauge("envio_sidecar_function_queue_depth", "Calls accepted and waiting to run.", () =>
      [...queues].map(([fn, queue]) => [{ fn }, queue.length] as const),
    );
    metrics.gauge("envio_sidecar_function_running", "Calls running now.", () =>
      [...running].map(([fn, n]) => [{ fn }, n] as const),
    );
    const droppedTotal = metrics.counter(
      "envio_sidecar_dropped_total",
      "Accepted calls dropped before running, by reason (rollback, shutdown).",
    );
    metrics.gauge("envio_sidecar_dedupe_ids", "Call ids remembered to dedupe redelivery.", () => [[{}, seen.size]]);
    const emitTotal = metrics.counter(
      "envio_sidecar_emit_total",
      "Webhooks by outcome (sent, rejected, undeliverable, abandoned, invalid).",
    );
    const emitRetries = metrics.counter("envio_sidecar_emit_retries_total", "Webhook delivery retries.");
    metrics.gauge("envio_sidecar_emits_pending", "Webhook deliveries in progress.", () => [[{}, pendingEmits.size]]);
    metrics.gauge("envio_sidecar_emit_breaker_open", "1 while new emits fail fast because the indexer is unreachable (open or half-open).", () => [
      [{}, breaker.snapshot().state === "closed" ? 0 : 1],
    ]);
    const breakerOpened = metrics.counter("envio_sidecar_emit_breaker_opened_total", "Times the emit breaker opened.");
    const jobRuns = metrics.counter("envio_sidecar_job_runs_total", "Job ticks by outcome (succeeded, failed, skipped).");
    const jobDurations = metrics.histogram("envio_sidecar_job_duration_seconds", "Time a job run took.");
    metrics.gauge("envio_sidecar_ready", "1 while the sidecar takes calls, 0 while starting or closing.", () => [
      [{}, ready ? 1 : 0],
    ]);

    const stopEmits = new AbortController();
    const indexerInternalUrl = options.indexerInternalUrl ?? env.indexerInternalUrl;
    const breaker = createEmitBreaker({
      failures: options.emitBreaker?.failures ?? env.emitBreakerFailures,
      cooldownMs: options.emitBreaker?.cooldownMs ?? env.emitBreakerCooldownMs,
      log,
      url: indexerInternalUrl,
      onOpen: () => breakerOpened.inc(),
    });
    const transport: EmitTransport = {
      indexerInternalUrl,
      webhookSecret: env.webhookSecret,
      breaker,
      ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
      retry: { ...DEFAULT_RETRY, maxMs: env.emitRetryMaxMs, ...options.retry },
      signal: stopEmits.signal,
      log,
      onSent: (webhook) => {
        counters.webhooksSent++;
        emitTotal.inc({ webhook, outcome: "sent" });
      },
      onFailed: (webhook, outcome) => {
        if (outcome !== "invalid") counters.webhooksFailed++;
        emitTotal.inc({ webhook, outcome });
      },
      onRetry: (webhook) => {
        emitRetries.inc({ webhook });
      },
      onPending: (sending) => {
        pendingEmits.add(sending);
        const done = () => {
          pendingEmits.delete(sending);
          settle();
        };
        sending.then(done, done);
      },
    };
    const indexer = createIndexerClient({
      url: options.graphqlUrl ?? env.graphqlUrl,
      role: env.graphqlRole,
      secret: env.graphqlSecret,
      responseLimit: env.responseLimit,
      ...(options.entities === undefined ? {} : { entities: options.entities }),
      ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
    });

    const queues = new Map<string, QueuedCall[]>();
    const running = new Map<string, number>();
    for (const name of Object.keys(contractFunctions)) {
      queues.set(name, []);
      running.set(name, 0);
    }
    // Accepted call ids with the block they came from. Ids are deterministic, so
    // a reorg re-sends the replayed blocks' calls under the same ids: rollback
    // forgets the ids above the rollback block, or they would be acked as
    // duplicates and never run.
    // A Map iterates in insertion order, so its first key is the oldest id.
    const seen = new Map<string, { readonly chainId: number; readonly blockNumber: number }>();
    const dedupeMax = Math.max(1, options.dedupeMax ?? env.dedupeMax);
    const remember = (id: string, chainId: number, blockNumber: number) => {
      seen.set(id, { chainId, blockNumber });
      if (seen.size > dedupeMax) {
        const oldest = seen.keys().next();
        if (oldest.done !== true) seen.delete(oldest.value);
      }
    };
    const forgetAbove = (chainId: number, rollbackToBlock: number): number => {
      let forgotten = 0;
      for (const [id, origin] of seen) {
        if (origin.chainId === chainId && origin.blockNumber > rollbackToBlock) {
          seen.delete(id);
          forgotten++;
        }
      }
      return forgotten;
    };
    const idleWaiters: Array<() => void> = [];
    const drainWaiters: Array<() => void> = [];
    const isIdle = () =>
      [...queues.values()].every((queue) => queue.length === 0) && [...running.values()].every((n) => n === 0);
    const isDrained = () => isIdle() && pendingEmits.size === 0 && runningJobs === 0;
    const settle = () => {
      if (isIdle()) for (const resolve of idleWaiters.splice(0)) resolve();
      if (isDrained()) for (const resolve of drainWaiters.splice(0)) resolve();
    };

    const defaultTimeoutMs = options.functionTimeoutMs ?? env.functionTimeoutMs;
    const settingsOf = (name: string) => {
      const fn = functions[name];
      if (typeof fn === "function") {
        return { run: fn, concurrency: 1, maxQueue: DEFAULT_MAX_QUEUE, timeoutMs: defaultTimeoutMs };
      }
      if (fn === undefined) throw new Error(`unreachable: no implementation for '${name}'`);
      return {
        run: fn.run,
        concurrency: Math.max(1, fn.concurrency ?? 1),
        maxQueue: Math.max(1, fn.maxQueue ?? DEFAULT_MAX_QUEUE),
        timeoutMs: fn.timeout === undefined ? defaultTimeoutMs : parseTimeout(name, fn.timeout),
      };
    };

    const runOne = async (item: QueuedCall) => {
      const { run, timeoutMs } = settingsOf(item.fn);
      const callLog = toUserLogger(rootLogger.child({ fn: item.fn, callId: item.call.id, chainId: item.call.chainId }));
      const controller = new AbortController();
      const emit = createEmit(contract, transport, {
        chainId: item.call.chainId,
        callId: item.call.id,
        signal: controller.signal,
      });
      let timer: NodeJS.Timeout | undefined;
      let outcome: "succeeded" | "failed" | "timed_out" = "failed";
      const startedAt = performance.now();
      try {
        const work = Promise.resolve().then(() =>
          run({
            input: item.input as SidecarFunctionInput<C, keyof C["functions"]>,
            call: item.call,
            emit,
            indexer,
            log: callLog,
            signal: controller.signal,
          }),
        );
        const finished =
          timeoutMs > 0
            ? await Promise.race([
                work.then(() => "done" as const),
                new Promise<"timeout">((resolve) => {
                  timer = setTimeout(() => resolve("timeout"), timeoutMs);
                }),
              ])
            : await work.then(() => "done" as const);
        if (finished === "timeout") {
          outcome = "timed_out";
          controller.abort(new Error(`function '${item.fn}' timed out after ${timeoutMs} ms`));
          counters.timedOut++;
          callLog.error("sidecar function timed out, freeing its slot", { timeoutMs });
          // The function cannot be stopped and keeps running detached; a late
          // failure must not surface as an unhandled rejection.
          work.catch((error: unknown) => {
            callLog.warn("timed out sidecar function failed later", error instanceof Error ? error : { error: String(error) });
          });
          return;
        }
        outcome = "succeeded";
        counters.ran++;
      } catch (error) {
        counters.failed++;
        callLog.error("sidecar function failed", error instanceof Error ? error : { error: String(error) });
      } finally {
        clearTimeout(timer);
        callsTotal.inc({ fn: item.fn, outcome });
        durations.observe({ fn: item.fn }, (performance.now() - startedAt) / 1_000);
      }
    };

    const pump = (name: string) => {
      const queue = queues.get(name);
      if (queue === undefined) return;
      const { concurrency } = settingsOf(name);
      while ((running.get(name) ?? 0) < concurrency && queue.length > 0) {
        const item = queue.shift();
        if (item === undefined) break;
        running.set(name, (running.get(name) ?? 0) + 1);
        void runOne(item).finally(() => {
          running.set(name, (running.get(name) ?? 1) - 1);
          pump(name);
          settle();
        });
      }
    };

    const internal = express();
    internal.use(express.json({ limit: "10mb" }));
    internal.get("/healthz", (_req, res) => {
      res.status(200).json({ status: "ok" });
    });
    internal.get("/readyz", (_req, res) => {
      res
        .status(ready ? 200 : 503)
        .json({ status: ready ? "ok" : closing ? "closing" : "starting", emitBreaker: breaker.snapshot() });
    });
    internal.get("/metrics", (_req, res) => {
      res.writeHead(200, { "content-type": PROMETHEUS_CONTENT_TYPE });
      res.end(metrics.render());
    });
    internal.post("/envio/calls", (req, res) => {
      if (closing) {
        res.status(503).set("retry-after", "1").json({ error: "shutting down" });
        return;
      }
      const body: unknown = req.body;
      if (!isPlainObject(body) || !Array.isArray(body.calls)) {
        res.status(400).json({ error: "expected { batchId, calls: [...] }" });
        return;
      }
      const batchId = typeof body.batchId === "string" ? body.batchId : "";
      const accepted: string[] = [];
      const rejected: Array<{ id: string; reason: string }> = [];
      const touched = new Set<string>();
      for (const raw of body.calls as unknown[]) {
        const problem = malformedCall(raw);
        if (problem !== null) {
          const id = isPlainObject(raw) && typeof raw.id === "string" ? raw.id : "";
          rejected.push({ id, reason: `malformed call: ${problem}` });
          callsTotal.inc({ fn: "_unknown", outcome: "rejected" });
          continue;
        }
        const wire = raw as WireCall;
        const def = contractFunctions[wire.fn];
        const queue = queues.get(wire.fn);
        if (def === undefined || queue === undefined) {
          rejected.push({ id: wire.id, reason: `unknown function: ${wire.fn}` });
          callsTotal.inc({ fn: "_unknown", outcome: "rejected" });
          continue;
        }
        if (seen.has(wire.id)) {
          counters.duplicates++;
          callsTotal.inc({ fn: wire.fn, outcome: "duplicate" });
          accepted.push(wire.id);
          continue;
        }
        if (queue.length >= settingsOf(wire.fn).maxQueue) {
          rejected.push({ id: wire.id, reason: "queue full" });
          callsTotal.inc({ fn: wire.fn, outcome: "rejected" });
          continue;
        }
        let input: unknown;
        try {
          input = S.parseOrThrow(wire.input, def.input);
        } catch (error) {
          rejected.push({
            id: wire.id,
            reason: `invalid input: ${error instanceof Error ? error.message : String(error)}`,
          });
          callsTotal.inc({ fn: wire.fn, outcome: "rejected" });
          continue;
        }
        queue.push({
          fn: wire.fn,
          input,
          call: {
            id: wire.id,
            chainId: wire.chainId,
            blockNumber: wire.blockNumber,
            blockTimestamp: wire.blockTimestamp,
            batchId,
          },
        });
        remember(wire.id, wire.chainId, wire.blockNumber);
        callsTotal.inc({ fn: wire.fn, outcome: "accepted" });
        accepted.push(wire.id);
        touched.add(wire.fn);
      }
      counters.accepted += accepted.length;
      counters.rejected += rejected.length;
      if (rejected.length > 0) {
        log.warn("rejected sidecar calls", { batchId, rejected });
      }
      res.status(202).json({ accepted, rejected });
      // The 202 is the acknowledgement that the calls are queued; work starts
      // only after it is on the wire.
      setImmediate(() => {
        for (const name of touched) pump(name);
      });
    });
    internal.post("/envio/rollback", (req, res) => {
      const body: unknown = req.body;
      if (!isPlainObject(body) || typeof body.chainId !== "number" || typeof body.rollbackToBlock !== "number") {
        res.status(400).json({ error: "expected { chainId, rollbackToBlock }" });
        return;
      }
      const notice: RollbackNotice = { chainId: body.chainId, rollbackToBlock: body.rollbackToBlock };
      let dropped = 0;
      for (const [name, queue] of queues) {
        const kept = queue.filter(
          (item) => !(item.call.chainId === notice.chainId && item.call.blockNumber > notice.rollbackToBlock),
        );
        dropped += queue.length - kept.length;
        queues.set(name, kept);
      }
      counters.dropped += dropped;
      if (dropped > 0) droppedTotal.inc({ reason: "rollback" }, dropped);
      const forgotten = forgetAbove(notice.chainId, notice.rollbackToBlock);
      log.info("rollback notice", { ...notice, dropped, forgottenCallIds: forgotten });
      Promise.resolve()
        .then(() => impl.onRollback?.(notice))
        .then(
          () => {
            res.status(200).json({ dropped });
          },
          (error: unknown) => {
            log.error("onRollback failed", error instanceof Error ? error : { error: String(error) });
            res.status(200).json({ dropped, onRollbackError: error instanceof Error ? error.message : String(error) });
          },
        )
        .finally(settle);
    });

    const pub = express();
    pub.use(express.json({ limit: "1mb" }));
    wrapAsyncRoutes(pub);
    pub.get("/healthz", (_req, res) => {
      res.status(200).json({ status: "ok" });
    });
    const routeEmit = createEmit(contract, transport);
    const app = Object.assign(pub, { indexer, emit: routeEmit, log }) as SidecarRoutesApp<C>;
    impl.routes?.(app);
    pub.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
      log.error("route failed", error instanceof Error ? error : { error: String(error) });
      if (!res.headersSent) res.status(500).json({ error: "internal error" });
    });

    const internalServer = await listen(internal, options.internalPort ?? env.internalPort, "127.0.0.1");
    let publicServer: Server;
    try {
      publicServer = await listen(pub, options.publicPort ?? env.publicPort, "0.0.0.0");
    } catch (error) {
      await closeServer(internalServer);
      throw error;
    }

    const timers: NodeJS.Timeout[] = [];
    const startupTicks: Array<() => void> = [];
    if (options.startJobs ?? true) {
      for (const [name, job] of Object.entries(jobs)) {
        const jobLog = toUserLogger(rootLogger.child({ job: name }));
        const jobEmit = createEmit(contract, transport);
        let inFlight = false;
        const tick = () => {
          if (inFlight) {
            jobLog.warn("job still running, skipping this tick");
            jobRuns.inc({ job: name, outcome: "skipped" });
            return;
          }
          inFlight = true;
          runningJobs++;
          const startedAt = performance.now();
          Promise.resolve()
            .then(() => job.run({ emit: jobEmit, indexer, log: jobLog }))
            .then(
              () => {
                jobRuns.inc({ job: name, outcome: "succeeded" });
              },
              (error: unknown) => {
                jobRuns.inc({ job: name, outcome: "failed" });
                jobLog.error("job failed", error instanceof Error ? error : { error: String(error) });
              },
            )
            .finally(() => {
              jobDurations.observe({ job: name }, (performance.now() - startedAt) / 1_000);
              inFlight = false;
              runningJobs--;
              settle();
            });
        };
        timers.push(setInterval(tick, parseEvery(job.every)));
        if (job.runOnStart === true) startupTicks.push(tick);
      }
    }
    ready = true;
    // Same tick as the interval's, so the start-up run counts as in flight: an
    // interval tick during it is skipped and close() waits for it.
    for (const tick of startupTicks) tick();
    log.info("sidecar started", {
      internalPort: portOf(internalServer),
      publicPort: portOf(publicServer),
      functions: Object.keys(contractFunctions),
      jobs: Object.keys(jobs),
    });

    const unfinished = (): CloseReport["abandoned"] => ({
      running: Object.fromEntries(running),
      queued: Object.fromEntries([...queues].map(([name, queue]) => [name, queue.length])),
      emits: pendingEmits.size,
      jobs: runningJobs,
    });

    const shutdown = async (graceMs: number): Promise<CloseReport> => {
      closing = true;
      ready = false;
      for (const timer of timers) clearInterval(timer);
      log.info("sidecar closing", { graceMs, ...unfinished() });
      let graceTimer: NodeJS.Timeout | undefined;
      const drained = await Promise.race([
        new Promise<true>((resolve) => {
          if (isDrained()) resolve(true);
          else drainWaiters.push(() => resolve(true));
        }),
        new Promise<false>((resolve) => {
          graceTimer = setTimeout(() => resolve(false), graceMs);
        }),
      ]);
      clearTimeout(graceTimer);
      const abandoned = unfinished();
      if (!drained) {
        // Running functions cannot be cancelled; queued ones must not start
        // once the process is on its way out.
        const droppedQueued = [...queues.values()].reduce((sum, queue) => sum + queue.length, 0);
        counters.dropped += droppedQueued;
        if (droppedQueued > 0) droppedTotal.inc({ reason: "shutdown" }, droppedQueued);
        for (const queue of queues.values()) queue.length = 0;
        log.warn("sidecar grace period over, abandoning unfinished work", { graceMs, ...abandoned });
      }
      // Retrying deliveries reject now instead of outliving the grace period;
      // emits made after close (a timed out function waking up) fail at once.
      stopEmits.abort(new Error("sidecar closed before it was delivered"));
      await Promise.all([closeServer(internalServer), closeServer(publicServer)]);
      log.info("sidecar stopped", { drained });
      return { drained, graceMs, abandoned };
    };
    let closed: Promise<CloseReport> | undefined;

    return {
      internalPort: portOf(internalServer),
      publicPort: portOf(publicServer),
      stats: () => ({
        ...counters,
        queued: Object.fromEntries([...queues].map(([name, queue]) => [name, queue.length])),
      }),
      waitIdle: () =>
        new Promise<void>((resolve) => {
          if (isIdle()) resolve();
          else idleWaiters.push(resolve);
        }),
      close: (closeOptions = {}) => {
        closed ??= shutdown(closeOptions.graceMs ?? options.graceMs ?? env.graceMs);
        return closed;
      },
    };
  };

  return { ...impl, contract, start };
}
