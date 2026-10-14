import express from "express";
import type { Server } from "node:http";
import * as S from "rescript-schema";
import { isSidecarContract, type SidecarContract, type SidecarFunctionInput } from "./contract.js";
import { createEmit, type Emit, type EmitTransport, type RetryPolicy } from "./emit.js";
import { readEnv } from "./env.js";
import { createRootLogger, toUserLogger, type SidecarLogger } from "./log.js";
import { createIndexerClient, type EntityMetaInput, type IndexerClient } from "./client.js";

export type SidecarCall = {
  readonly id: string;
  readonly chainId: number;
  readonly blockNumber: number;
  readonly blockTimestamp: number;
  readonly batchId: string;
};

export type SidecarFunctionArgs<C extends SidecarContract, K extends keyof C["functions"]> = {
  readonly input: SidecarFunctionInput<C, K>;
  readonly call: SidecarCall;
  readonly emit: Emit<C>;
  readonly indexer: IndexerClient;
  readonly log: SidecarLogger;
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
  readonly retry?: RetryPolicy;
};

export type SidecarStats = {
  readonly accepted: number;
  readonly rejected: number;
  readonly duplicates: number;
  readonly ran: number;
  readonly failed: number;
  readonly dropped: number;
  readonly queued: Readonly<Record<string, number>>;
  readonly webhooksSent: number;
  readonly webhooksFailed: number;
};

export type RunningSidecar = {
  readonly internalPort: number;
  readonly publicPort: number;
  readonly close: () => Promise<void>;
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
const SEEN_IDS_CAP = 10_000;

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
      dropped: 0,
      webhooksSent: 0,
      webhooksFailed: 0,
    };
    const transport: EmitTransport = {
      indexerInternalUrl: options.indexerInternalUrl ?? env.indexerInternalUrl,
      webhookSecret: env.webhookSecret,
      ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
      ...(options.retry === undefined ? {} : { retry: options.retry }),
      log,
      onSent: () => {
        counters.webhooksSent++;
      },
      onFailed: () => {
        counters.webhooksFailed++;
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
    const seen = new Set<string>();
    const seenOrder: string[] = [];
    const remember = (id: string) => {
      seen.add(id);
      seenOrder.push(id);
      if (seenOrder.length > SEEN_IDS_CAP) {
        const oldest = seenOrder.shift();
        if (oldest !== undefined) seen.delete(oldest);
      }
    };
    const idleWaiters: Array<() => void> = [];
    const isIdle = () =>
      [...queues.values()].every((queue) => queue.length === 0) && [...running.values()].every((n) => n === 0);
    const notifyIfIdle = () => {
      if (!isIdle()) return;
      for (const resolve of idleWaiters.splice(0)) resolve();
    };

    const settingsOf = (name: string) => {
      const fn = functions[name];
      if (typeof fn === "function") return { run: fn, concurrency: 1, maxQueue: DEFAULT_MAX_QUEUE };
      if (fn === undefined) throw new Error(`unreachable: no implementation for '${name}'`);
      return {
        run: fn.run,
        concurrency: Math.max(1, fn.concurrency ?? 1),
        maxQueue: Math.max(1, fn.maxQueue ?? DEFAULT_MAX_QUEUE),
      };
    };

    const runOne = async (item: QueuedCall) => {
      const { run } = settingsOf(item.fn);
      const callLog = toUserLogger(rootLogger.child({ fn: item.fn, callId: item.call.id, chainId: item.call.chainId }));
      const emit = createEmit(contract, transport, { chainId: item.call.chainId, callId: item.call.id });
      try {
        await run({
          input: item.input as SidecarFunctionInput<C, keyof C["functions"]>,
          call: item.call,
          emit,
          indexer,
          log: callLog,
        });
        counters.ran++;
      } catch (error) {
        counters.failed++;
        callLog.error("sidecar function failed", error instanceof Error ? error : { error: String(error) });
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
          notifyIfIdle();
        });
      }
    };

    const internal = express();
    internal.use(express.json({ limit: "10mb" }));
    let ready = false;
    internal.get("/healthz", (_req, res) => {
      res.status(200).json({ status: "ok" });
    });
    internal.get("/readyz", (_req, res) => {
      res.status(ready ? 200 : 503).json({ status: ready ? "ok" : "starting" });
    });
    internal.post("/envio/calls", (req, res) => {
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
          continue;
        }
        const wire = raw as WireCall;
        const def = contractFunctions[wire.fn];
        const queue = queues.get(wire.fn);
        if (def === undefined || queue === undefined) {
          rejected.push({ id: wire.id, reason: `unknown function: ${wire.fn}` });
          continue;
        }
        if (seen.has(wire.id)) {
          counters.duplicates++;
          accepted.push(wire.id);
          continue;
        }
        if (queue.length >= settingsOf(wire.fn).maxQueue) {
          rejected.push({ id: wire.id, reason: "queue full" });
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
          continue;
        }
        queue.push({
          fn: wire.fn,
          input,
          call: {
            id: wire.id,
            chainId: wire.chainId,
            blockNumber: wire.blockNumber,
            blockTimestamp: wire.blockTimestamp ?? 0,
            batchId,
          },
        });
        remember(wire.id);
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
      log.info("rollback notice", { ...notice, dropped });
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
        .finally(notifyIfIdle);
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
    if (options.startJobs ?? true) {
      for (const [name, job] of Object.entries(jobs)) {
        const jobLog = toUserLogger(rootLogger.child({ job: name }));
        const jobEmit = createEmit(contract, transport);
        let inFlight = false;
        const tick = () => {
          if (inFlight) {
            jobLog.warn("job still running, skipping this tick");
            return;
          }
          inFlight = true;
          Promise.resolve()
            .then(() => job.run({ emit: jobEmit, indexer, log: jobLog }))
            .catch((error: unknown) => {
              jobLog.error("job failed", error instanceof Error ? error : { error: String(error) });
            })
            .finally(() => {
              inFlight = false;
            });
        };
        timers.push(setInterval(tick, parseEvery(job.every)));
      }
    }
    ready = true;
    log.info("sidecar started", {
      internalPort: portOf(internalServer),
      publicPort: portOf(publicServer),
      functions: Object.keys(contractFunctions),
      jobs: Object.keys(jobs),
    });

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
      close: async () => {
        ready = false;
        for (const timer of timers) clearInterval(timer);
        await Promise.all([closeServer(internalServer), closeServer(publicServer)]);
        log.info("sidecar stopped");
      },
    };
  };

  return { ...impl, contract, start };
}
