import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createRequire } from "node:module";
import { Writable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { defineSidecar, S } from "envio";
import {
  createSidecar,
  createSidecarSql,
  readEnv,
  SidecarEmitError,
  SidecarSqlDisabledError,
  type SidecarSql,
  sidecarContractHash,
  type RetryPolicy,
  type RunningSidecar,
  type SidecarImpl,
} from "envio/sidecar";

type Received = {
  readonly name: string;
  readonly headers: IncomingMessage["headers"];
  readonly body: unknown;
};

type Reply = { readonly status: number; readonly body?: unknown; readonly headers?: Record<string, string> };

type FakeIndexer = {
  readonly url: string;
  readonly received: Received[];
  readonly close: () => Promise<void>;
  /** Stops listening (connections are refused) and comes back on the same port. */
  readonly stop: () => Promise<void>;
  readonly restart: () => Promise<void>;
};

const readBody = (request: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });

const send = (response: ServerResponse, reply: Reply) => {
  const payload = reply.body === undefined ? "" : JSON.stringify(reply.body);
  response.writeHead(reply.status, { "content-type": "application/json", ...reply.headers });
  response.end(payload);
};

// Answers like the indexer's loopback listener: 202 with an id, 400 when the
// chain is missing, unless the test scripts something else.
const fakeIndexer = async (respond?: (received: Received, n: number) => Reply | undefined): Promise<FakeIndexer> => {
  const received: Received[] = [];
  const server: Server = createServer((request, response) => {
    void readBody(request).then((raw) => {
      const match = /^\/webhooks\/([^/?]+)/.exec(request.url ?? "");
      if (request.method !== "POST" || match === null) {
        send(response, { status: 404, body: { error: "not found" } });
        return;
      }
      const item: Received = { name: match[1] as string, headers: request.headers, body: raw === "" ? undefined : JSON.parse(raw) };
      received.push(item);
      const scripted = respond?.(item, received.length);
      if (scripted !== undefined) {
        send(response, scripted);
        return;
      }
      const chainId = request.headers["x-envio-chain-id"];
      if (typeof chainId !== "string") {
        send(response, { status: 400, body: { error: "chain", detail: "x-envio-chain-id missing" } });
        return;
      }
      send(response, { status: 202, body: { id: `wh_${received.length}`, chainId: Number(chainId) } });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no port");
  const port = address.port;
  const close = () =>
    new Promise<void>((resolve) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.closeAllConnections();
      server.close(() => resolve());
    });
  return {
    url: `http://127.0.0.1:${port}`,
    received,
    close,
    stop: close,
    restart: () => new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve)),
  };
};

const contract = defineSidecar({
  functions: {
    priceSwap: { input: { swapId: S.string, amount: S.bigint } },
    notify: { input: { text: S.string } },
  },
  webhooks: {
    swapPriced: { body: { swapId: S.string, usd: S.number, amount: S.bigint } },
    tick: { body: { at: S.number } },
  },
});
type Contract = typeof contract;

const call = (id: string, fn: string, input: unknown, extra: Partial<{ chainId: number; blockNumber: number }> = {}) => ({
  id,
  fn,
  chainId: extra.chainId ?? 1,
  blockNumber: extra.blockNumber ?? 100,
  blockTimestamp: 1760440000,
  input,
});

const postJson = async (url: string, body: unknown) => {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: text === "" ? undefined : (JSON.parse(text) as unknown) };
};

const deferred = <T = void>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
};

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const startSidecar = async (
  indexer: FakeIndexer,
  impl: SidecarImpl<Contract>,
  options: { startJobs?: boolean; env?: NodeJS.ProcessEnv; retry?: RetryPolicy; entry?: string } = {},
): Promise<RunningSidecar> => {
  // Off unless a test is about the breaker: other tests count every attempt.
  const env = { ENVIO_EMIT_BREAKER_FAILURES: "0", ...(options.env ?? process.env) };
  const sidecar = createSidecar(contract, impl);
  const running = await sidecar.start({
    internalPort: 0,
    publicPort: 0,
    indexerInternalUrl: indexer.url,
    logLevel: "silent",
    retry: options.retry ?? { attempts: 4, baseMs: 1, capMs: 5 },
    startJobs: options.startJobs ?? false,
    env,
    ...(options.entry === undefined ? {} : { entry: options.entry }),
  });
  cleanups.push(running.close);
  return running;
};

const noop = { priceSwap: async () => {}, notify: async () => {} };

const envioVersion = (createRequire(import.meta.url)("envio/package.json") as { version: string }).version;

describe("sidecar runtime: calls", () => {
  it("acknowledges each call before running it, rejects what it cannot run, dedupes redelivery", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const gate = deferred();
    const started = deferred();
    const seenInputs: unknown[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async ({ input }) => {
          seenInputs.push(input);
          started.resolve();
          await gate.promise;
        },
        notify: async () => {},
      },
    });
    const url = `http://127.0.0.1:${running.internalPort}/envio/calls`;
    const answer = await postJson(url, {
      batchId: "b-1",
      calls: [
        call("1:100:7:0", "priceSwap", { swapId: "s1", amount: "1500000000000000000" }),
        call("1:100:8:0", "priceSwp", { swapId: "s2", amount: "1" }),
        call("1:100:9:0", "priceSwap", { swapId: "s3", amount: 12 }),
        call("1:100:7:0", "priceSwap", { swapId: "s1", amount: "1500000000000000000" }),
        "nonsense",
      ],
    });
    // The gate is still closed, so the 202 cannot have waited for the function.
    expect({ status: answer.status, body: answer.body }).toEqual({
      status: 202,
      body: {
        accepted: ["1:100:7:0", "1:100:7:0"],
        rejected: [
          { id: "1:100:8:0", reason: "unknown function: priceSwp" },
          { id: "1:100:9:0", reason: expect.stringMatching(/^invalid input: /) },
          { id: "", reason: "malformed call: call is not an object" },
        ],
      },
    });
    await started.promise;
    gate.resolve();
    await running.waitIdle();
    expect({ seenInputs, stats: running.stats() }).toEqual({
      seenInputs: [{ swapId: "s1", amount: 1500000000000000000n }],
      stats: {
        accepted: 2,
        rejected: 3,
        duplicates: 1,
        ran: 1,
        failed: 0,
        timedOut: 0,
        dropped: 0,
        queued: { priceSwap: 0, notify: 0 },
        webhooksSent: 0,
        webhooksFailed: 0,
      },
    });
  });

  it("emits webhooks bound to the call: idempotency key, chain header, bigint as string", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const results: unknown[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async ({ input, emit }) => {
          results.push(await emit.swapPriced({ swapId: input.swapId, usd: 4123.5, amount: input.amount * 2n }));
          results.push(await emit.swapPriced({ swapId: input.swapId, usd: 1, amount: 0n }));
        },
        notify: async () => {},
      },
    });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-2",
      calls: [call("1:100:7:0", "priceSwap", { swapId: "s1", amount: "10" }, { chainId: 137 })],
    });
    await running.waitIdle();
    expect({
      results,
      received: indexer.received.map((r) => ({
        name: r.name,
        key: r.headers["idempotency-key"],
        chain: r.headers["x-envio-chain-id"],
        body: r.body,
      })),
      sent: running.stats().webhooksSent,
    }).toEqual({
      results: [
        { id: "wh_1", chainId: 137 },
        { id: "wh_2", chainId: 137 },
      ],
      received: [
        { name: "swapPriced", key: "1:100:7:0#0", chain: "137", body: { swapId: "s1", usd: 4123.5, amount: "20" } },
        { name: "swapPriced", key: "1:100:7:0#1", chain: "137", body: { swapId: "s1", usd: 1, amount: "0" } },
      ],
      sent: 2,
    });
  });

  it("runs one call per function at a time unless concurrency says otherwise", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const observed: Record<string, { peak: number; now: number }> = {
      priceSwap: { peak: 0, now: 0 },
      notify: { peak: 0, now: 0 },
    };
    const track = async (name: "priceSwap" | "notify") => {
      const slot = observed[name];
      slot.now++;
      slot.peak = Math.max(slot.peak, slot.now);
      await new Promise((resolve) => setTimeout(resolve, 15));
      slot.now--;
    };
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: () => track("priceSwap"),
        notify: { concurrency: 3, run: () => track("notify") },
      },
    });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-3",
      calls: [
        ...[1, 2, 3, 4].map((n) => call(`1:100:${n}:0`, "priceSwap", { swapId: `s${n}`, amount: "1" })),
        ...[1, 2, 3, 4].map((n) => call(`1:100:${n}:1`, "notify", { text: `t${n}` })),
      ],
    });
    await running.waitIdle();
    expect({ peaks: { priceSwap: observed.priceSwap?.peak, notify: observed.notify?.peak }, ran: running.stats().ran }).toEqual({
      peaks: { priceSwap: 1, notify: 3 },
      ran: 8,
    });
  });

  it("logs a throwing function and keeps serving", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    let calls = 0;
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async () => {
          calls++;
          throw new Error("price feed down");
        },
        notify: async () => {},
      },
    });
    const url = `http://127.0.0.1:${running.internalPort}/envio/calls`;
    await postJson(url, { batchId: "b-4", calls: [call("1:1:1:0", "priceSwap", { swapId: "a", amount: "1" })] });
    await running.waitIdle();
    const second = await postJson(url, { batchId: "b-5", calls: [call("1:1:2:0", "priceSwap", { swapId: "b", amount: "1" })] });
    await running.waitIdle();
    expect({ calls, secondStatus: second.status, failed: running.stats().failed }).toEqual({
      calls: 2,
      secondStatus: 202,
      failed: 2,
    });
  });

  it("times out a slow function: counted, its slot freed, its late emit refused (per function or ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS)", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const gate = deferred();
    cleanups.push(async () => gate.resolve());
    const lateEmit = deferred<string>();
    const events: string[] = [];
    const running = await startSidecar(
      indexer,
      {
        functions: {
          priceSwap: {
            timeout: "40ms",
            run: async ({ input, call, emit, signal }) => {
              events.push(`start ${call.id}`);
              if (input.swapId !== "slow") return;
              signal.addEventListener("abort", () => events.push(`aborted ${call.id}`));
              await gate.promise;
              try {
                await emit.swapPriced({ swapId: input.swapId, usd: 1, amount: input.amount });
                lateEmit.resolve("sent");
              } catch (error) {
                lateEmit.resolve(error instanceof SidecarEmitError ? error.message : "wrong error");
              }
            },
          },
          // No per-function timeout: the env default applies.
          notify: async () => {
            await gate.promise;
          },
        },
      },
      { env: { ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS: "20" } },
    );
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-16",
      calls: [
        call("1:100:1:0", "priceSwap", { swapId: "slow", amount: "1" }),
        call("1:100:2:0", "priceSwap", { swapId: "fast", amount: "1" }),
        call("1:100:3:0", "notify", { text: "stuck" }),
      ],
    });
    // Both functions run one call at a time, so the fast call can only start
    // once the slow one's slot is freed by the timeout.
    await running.waitIdle();
    gate.resolve();
    expect({
      events,
      lateEmit: await lateEmit.promise,
      received: indexer.received.length,
      stats: running.stats(),
    }).toEqual({
      events: ["start 1:100:1:0", "aborted 1:100:1:0", "start 1:100:2:0"],
      lateEmit: "Webhook 'swapPriced': abandoned: function 'priceSwap' timed out after 40 ms",
      received: 0,
      stats: expect.objectContaining({ ran: 1, failed: 0, timedOut: 2 }),
    });
  });

  it("remembers the last ENVIO_SIDECAR_DEDUPE_MAX call ids (100k by default) and evicts the oldest", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const ranIds: string[] = [];
    const running = await startSidecar(
      indexer,
      {
        functions: {
          ...noop,
          notify: async ({ call }) => {
            ranIds.push(call.id);
          },
        },
      },
      { env: { ENVIO_SIDECAR_DEDUPE_MAX: "2" } },
    );
    const url = `http://127.0.0.1:${running.internalPort}/envio/calls`;
    const send = async (batchId: string, ids: string[]) => {
      await postJson(url, { batchId, calls: ids.map((id) => call(id, "notify", { text: id })) });
      await running.waitIdle();
    };
    await send("b-17", ["1:1:1:0", "1:1:2:0", "1:1:3:0"]);
    await send("b-18", ["1:1:1:0", "1:1:3:0"]);
    expect({ ranIds, duplicates: running.stats().duplicates }).toEqual({
      ranIds: ["1:1:1:0", "1:1:2:0", "1:1:3:0", "1:1:1:0"],
      duplicates: 1,
    });
  });

  it("drops queued calls above a rolled back block and tells the user", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const gate = deferred();
    const started = deferred();
    const ranIds: string[] = [];
    const notices: unknown[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async ({ call }) => {
          ranIds.push(call.id);
          started.resolve();
          await gate.promise;
        },
        notify: async () => {},
      },
      onRollback: async (notice) => {
        notices.push(notice);
      },
    });
    const base = `http://127.0.0.1:${running.internalPort}`;
    await postJson(`${base}/envio/calls`, {
      batchId: "b-6",
      calls: [
        call("1:10:0:0", "priceSwap", { swapId: "a", amount: "1" }, { blockNumber: 10 }),
        call("1:12:0:0", "priceSwap", { swapId: "b", amount: "1" }, { blockNumber: 12 }),
        call("1:20:0:0", "priceSwap", { swapId: "c", amount: "1" }, { blockNumber: 20 }),
        call("1:30:0:0", "priceSwap", { swapId: "d", amount: "1" }, { blockNumber: 30 }),
        call("2:30:0:0", "priceSwap", { swapId: "e", amount: "1" }, { blockNumber: 30, chainId: 2 }),
      ],
    });
    await started.promise;
    const rollback = await postJson(`${base}/envio/rollback`, { chainId: 1, rollbackToBlock: 15 });
    gate.resolve();
    await running.waitIdle();
    expect({ rollback, ranIds, notices, dropped: running.stats().dropped }).toEqual({
      rollback: { status: 200, body: { dropped: 2 } },
      ranIds: ["1:10:0:0", "1:12:0:0", "2:30:0:0"],
      notices: [{ chainId: 1, rollbackToBlock: 15 }],
      dropped: 2,
    });
  });

  it("leaves blockTimestamp out for block handler calls instead of inventing one", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const timestamps: Array<[string, number | undefined]> = [];
    const running = await startSidecar(indexer, {
      functions: {
        ...noop,
        notify: async ({ call }) => {
          timestamps.push([call.id, call.blockTimestamp]);
        },
      },
    });
    const { blockTimestamp: _, ...blockCall } = call("1:5:b0:0", "notify", { text: "block" }, { blockNumber: 5 });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-12",
      calls: [blockCall, call("1:6:3:0", "notify", { text: "event" }, { blockNumber: 6 })],
    });
    await running.waitIdle();
    expect(timestamps).toEqual([
      ["1:5:b0:0", undefined],
      ["1:6:3:0", 1760440000],
    ]);
  });

  it("forgets call ids above a rolled back block, so the replayed blocks' calls run again", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const ranIds: string[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async ({ call }) => {
          ranIds.push(call.id);
        },
        notify: async () => {},
      },
    });
    const base = `http://127.0.0.1:${running.internalPort}`;
    const batch = (batchId: string) => ({
      batchId,
      calls: [
        call("1:10:0:0", "priceSwap", { swapId: "kept", amount: "1" }, { blockNumber: 10 }),
        call("1:20:0:0", "priceSwap", { swapId: "reorged", amount: "1" }, { blockNumber: 20 }),
        call("2:20:0:0", "priceSwap", { swapId: "other chain", amount: "1" }, { blockNumber: 20, chainId: 2 }),
      ],
    });
    await postJson(`${base}/envio/calls`, batch("b-8"));
    await running.waitIdle();
    const rollback = await postJson(`${base}/envio/rollback`, { chainId: 1, rollbackToBlock: 15 });
    // The indexer reprocesses blocks above 15 and re-sends their calls under the same ids.
    const resent = await postJson(`${base}/envio/calls`, batch("b-9"));
    await running.waitIdle();
    expect({ rollback, resent, ranIds, duplicates: running.stats().duplicates }).toEqual({
      rollback: { status: 200, body: { dropped: 0 } },
      resent: { status: 202, body: { accepted: ["1:10:0:0", "1:20:0:0", "2:20:0:0"], rejected: [] } },
      ranIds: ["1:10:0:0", "1:20:0:0", "2:20:0:0", "1:20:0:0"],
      duplicates: 2,
    });
  });
});

describe("sidecar runtime: webhooks from outside a call", () => {
  it("retries a busy indexer and gives up on a refusal", async () => {
    let failures = 0;
    const indexer = await fakeIndexer((received, n) => {
      if (received.name === "tick" && n <= 2) {
        failures++;
        return { status: 503 };
      }
      if (received.name === "external") {
        return { status: 400, body: { error: "schema", detail: "no handler for external" } };
      }
      return undefined;
    });
    cleanups.push(indexer.close);
    const outcomes: unknown[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        ...noop,
        notify: async ({ emit }) => {
          outcomes.push(await emit.tick({ at: 1 }, { chainId: 5 }));
          try {
            await emit.raw("sidecar.ack", { x: 1 });
          } catch (error) {
            outcomes.push(error instanceof SidecarEmitError ? `invalid name: ${error.message}` : "wrong error");
          }
          try {
            await emit.raw("external", { ok: true });
          } catch (error) {
            outcomes.push(
              error instanceof SidecarEmitError ? { status: error.status, detail: error.detail } : "wrong error",
            );
          }
        },
      },
    });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-7",
      calls: [call("1:1:1:0", "notify", { text: "hi" })],
    });
    await running.waitIdle();
    expect({ outcomes, failures, received: indexer.received.map((r) => [r.name, r.headers["x-envio-chain-id"]]), stats: running.stats() }).toEqual({
      outcomes: [
        { id: "wh_3", chainId: 5 },
        expect.stringMatching(/^invalid name: Webhook 'sidecar\.ack': invalid webhook name/),
        { status: 400, detail: { error: "schema", detail: "no handler for external" } },
      ],
      failures: 2,
      received: [
        ["tick", "5"],
        ["tick", "5"],
        ["tick", "5"],
        ["external", "1"],
      ],
      stats: expect.objectContaining({ ran: 1, failed: 0, webhooksSent: 1, webhooksFailed: 1 }),
    });
  });

  it("keeps retrying a busy indexer for ENVIO_EMIT_RETRY_MAX_MS, then rejects", async () => {
    const indexer = await fakeIndexer(() => ({ status: 503 }));
    cleanups.push(indexer.close);
    const outcome = deferred<{ message: string; elapsed: number }>();
    const running = await startSidecar(
      indexer,
      {
        functions: {
          ...noop,
          notify: async ({ emit }) => {
            const startedAt = Date.now();
            try {
              await emit.tick({ at: 1 });
              outcome.resolve({ message: "sent", elapsed: Date.now() - startedAt });
            } catch (error) {
              outcome.resolve({
                message: error instanceof SidecarEmitError ? error.message : "wrong error",
                elapsed: Date.now() - startedAt,
              });
            }
          },
        },
      },
      { env: { ENVIO_EMIT_RETRY_MAX_MS: "150" }, retry: { baseMs: 5, capMs: 20 } },
    );
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-19",
      calls: [call("1:1:1:0", "notify", { text: "hi" })],
    });
    const { message, elapsed } = await outcome.promise;
    await running.waitIdle();
    expect({
      message,
      withinBudget: elapsed >= 150 && elapsed < 1_000,
      // Doubling from 5 ms with jitter, capped at 20 ms: well over 5 tries in 150 ms.
      manyAttempts: indexer.received.length >= 5,
      webhooksFailed: running.stats().webhooksFailed,
    }).toEqual({
      message: expect.stringMatching(/^Webhook 'tick': undeliverable after \d+ attempts in \d+ ms: status 503$/),
      withinBudget: true,
      manyAttempts: true,
      webhooksFailed: 1,
    });
  });

  it("waits as long as a 503's retry-after asks", async () => {
    const indexer = await fakeIndexer((_received, n) =>
      n === 1 ? { status: 503, headers: { "retry-after": "1" } } : undefined,
    );
    cleanups.push(indexer.close);
    const times: number[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        ...noop,
        notify: async ({ emit }) => {
          await emit.tick({ at: 1 }, { chainId: 1 });
        },
      },
    });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-20",
      calls: [call("1:1:1:0", "notify", { text: "hi" })],
    });
    const startedAt = Date.now();
    await running.waitIdle();
    times.push(Date.now() - startedAt);
    expect({
      received: indexer.received.length,
      waitedForRetryAfter: (times[0] ?? 0) >= 950,
      sent: running.stats().webhooksSent,
    }).toEqual({ received: 2, waitedForRetryAfter: true, sent: 1 });
  });

  it("rejects a body that does not match the contract before sending anything", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const outcomes: unknown[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        ...noop,
        notify: async ({ emit }) => {
          for (const body of [{ at: "soon" }, { swapId: "s1", usd: "4123.5", amount: 1n }, { swapId: "s1", usd: 1 }]) {
            try {
              await (body.swapId === undefined ? emit.tick : emit.swapPriced)(body as never);
              outcomes.push("sent");
            } catch (error) {
              outcomes.push(error instanceof SidecarEmitError ? error.message : "wrong error");
            }
          }
        },
      },
    });
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-10",
      calls: [call("1:1:1:0", "notify", { text: "hi" })],
    });
    await running.waitIdle();
    expect({ outcomes, received: indexer.received.length }).toEqual({
      outcomes: [
        expect.stringMatching(/^Webhook 'tick': body does not match the contract: /),
        expect.stringMatching(/^Webhook 'swapPriced': body does not match the contract: /),
        expect.stringMatching(/^Webhook 'swapPriced': body does not match the contract: /),
      ],
      received: 0,
    });
  });

  it("runs jobs on their interval, one run at a time", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    let overlapping = 0;
    let inFlight = 0;
    const running = await startSidecar(
      indexer,
      {
        functions: noop,
        jobs: {
          refresh: {
            every: "10ms",
            run: async ({ emit }) => {
              inFlight++;
              if (inFlight > 1) overlapping++;
              await emit.tick({ at: Date.now() }, { chainId: 1 });
              await new Promise((resolve) => setTimeout(resolve, 25));
              inFlight--;
            },
          },
        },
      },
      { startJobs: true },
    );
    await new Promise((resolve) => setTimeout(resolve, 120));
    await running.close();
    cleanups.pop();
    const ticks = indexer.received.filter((r) => r.name === "tick").length;
    expect({ overlapping, atLeastTwo: ticks >= 2, boundedBySerialRuns: ticks <= 6 }).toEqual({
      overlapping: 0,
      atLeastTwo: true,
      boundedBySerialRuns: true,
    });
  });
});

describe("sidecar runtime: emit circuit breaker", () => {
  // A route that emits once and reports how it went, so a test can emit while
  // other emits are still retrying.
  const emitRoute: SidecarImpl<Contract> = {
    functions: noop,
    routes: (app) => {
      app.post("/emit", async (req, res) => {
        const startedAt = Date.now();
        try {
          await app.emit.tick({ at: Number(req.body.at) }, { chainId: 1 });
          res.json({ ok: true });
        } catch (error) {
          res.json({ error: error instanceof SidecarEmitError ? error.message : "wrong error", ms: Date.now() - startedAt });
        }
      });
    },
  };
  const emitVia = (running: RunningSidecar, at: number) =>
    postJson(`http://127.0.0.1:${running.publicPort}/emit`, { at }).then((response) => response.body as { ok?: true; error?: string; ms?: number });
  const breakerOf = async (running: RunningSidecar) => {
    const ready = await fetch(`http://127.0.0.1:${running.internalPort}/readyz`).then((response) => response.json() as Promise<{ emitBreaker: unknown }>);
    const metrics = await fetch(`http://127.0.0.1:${running.internalPort}/metrics`).then((response) => response.text());
    return {
      readyz: ready.emitBreaker,
      metrics: metrics.split("\n").filter((line) => /^envio_sidecar_emit_(breaker|total\{webhook="tick",outcome="unreachable")/.test(line)),
    };
  };

  it("opens after ENVIO_EMIT_BREAKER_FAILURES connection failures, then fails new emits fast; answers never open it", async () => {
    const indexer = await fakeIndexer((received) => {
      const at = (received.body as { at: number }).at;
      if (at === 400) return { status: 400, body: { error: "schema" } };
      if (at === 503) return { status: 503, headers: { "retry-after": "0" } };
      return undefined;
    });
    cleanups.push(indexer.close);
    const running = await startSidecar(indexer, emitRoute, {
      env: { ENVIO_EMIT_BREAKER_FAILURES: "3", ENVIO_EMIT_BREAKER_COOLDOWN_MS: "60000" },
      retry: { attempts: 1, baseMs: 1, capMs: 1 },
    });
    // Refusals and busy answers come from a live indexer.
    const answered = [];
    for (let i = 0; i < 4; i++) answered.push(await emitVia(running, i % 2 === 0 ? 400 : 503));
    const afterAnswers = await breakerOf(running);
    await indexer.stop();
    const down = [];
    for (let i = 0; i < 3; i++) down.push(await emitVia(running, i));
    const fast = await emitVia(running, 9);
    expect({ answered: answered.map((r) => r.error), afterAnswers, down: down.map((r) => r.error), fast: { error: fast.error, quick: (fast.ms ?? 1_000) < 50 }, breaker: await breakerOf(running) }).toEqual({
      answered: [
        "Webhook 'tick': indexer rejected it (400)",
        expect.stringMatching(/^Webhook 'tick': undeliverable after 1 attempts in \d+ ms: status 503$/),
        "Webhook 'tick': indexer rejected it (400)",
        expect.stringMatching(/^Webhook 'tick': undeliverable after 1 attempts in \d+ ms: status 503$/),
      ],
      afterAnswers: { readyz: { state: "closed", consecutiveFailures: 0 }, metrics: ["envio_sidecar_emit_breaker_open 0"] },
      down: [
        expect.stringMatching(/^Webhook 'tick': undeliverable after 1 attempts/),
        expect.stringMatching(/^Webhook 'tick': undeliverable after 1 attempts/),
        expect.stringMatching(/^Webhook 'tick': undeliverable after 1 attempts/),
      ],
      fast: { error: `Webhook 'tick': indexer unreachable at ${indexer.url}, breaker open`, quick: true },
      breaker: {
        readyz: { state: "open", consecutiveFailures: 3 },
        metrics: [
          'envio_sidecar_emit_total{webhook="tick",outcome="unreachable"} 1',
          "envio_sidecar_emit_breaker_open 1",
          "envio_sidecar_emit_breaker_opened_total 1",
        ],
      },
    });
  });

  it("after ENVIO_EMIT_BREAKER_COOLDOWN_MS the next emit probes once: a failed probe re-opens, an answer closes", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const running = await startSidecar(indexer, emitRoute, {
      env: { ENVIO_EMIT_BREAKER_FAILURES: "2", ENVIO_EMIT_BREAKER_COOLDOWN_MS: "100" },
      retry: { attempts: 1, baseMs: 1, capMs: 1 },
    });
    await indexer.stop();
    await emitVia(running, 1);
    await emitVia(running, 2);
    const open = await emitVia(running, 3);
    await new Promise((resolve) => setTimeout(resolve, 150));
    const failedProbe = await emitVia(running, 4);
    const reopened = await emitVia(running, 5);
    await indexer.restart();
    await new Promise((resolve) => setTimeout(resolve, 150));
    const halfOpen = await breakerOf(running);
    const probe = await emitVia(running, 6);
    const after = await emitVia(running, 7);
    expect({
      open: open.error,
      failedProbe: failedProbe.error,
      reopened: reopened.error,
      halfOpen: halfOpen.readyz,
      probe,
      after,
      breaker: await breakerOf(running),
      delivered: indexer.received.map((r) => (r.body as { at: number }).at),
    }).toEqual({
      open: `Webhook 'tick': indexer unreachable at ${indexer.url}, breaker open`,
      failedProbe: expect.stringMatching(new RegExp(`^Webhook 'tick': indexer unreachable at ${indexer.url}, breaker open \\(probe failed: .+\\)$`)),
      reopened: `Webhook 'tick': indexer unreachable at ${indexer.url}, breaker open`,
      halfOpen: { state: "half-open", consecutiveFailures: 3 },
      probe: { ok: true },
      after: { ok: true },
      breaker: {
        readyz: { state: "closed", consecutiveFailures: 0 },
        metrics: [
          'envio_sidecar_emit_total{webhook="tick",outcome="unreachable"} 3',
          "envio_sidecar_emit_breaker_open 0",
          "envio_sidecar_emit_breaker_opened_total 1",
        ],
      },
      delivered: [6, 7],
    });
  });

  it("an indexer restart of a moment still delivers the emits that were already retrying (wiki 09 scenario 4)", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const running = await startSidecar(indexer, emitRoute, {
      env: { ENVIO_EMIT_BREAKER_FAILURES: "2", ENVIO_EMIT_BREAKER_COOLDOWN_MS: "60000" },
      retry: { maxMs: 10_000, baseMs: 20, capMs: 50 },
    });
    await indexer.stop();
    const retrying = [emitVia(running, 1), emitVia(running, 2)];
    await new Promise((resolve) => setTimeout(resolve, 300));
    const whileOpen = await emitVia(running, 3);
    const duringRestart = await breakerOf(running);
    await indexer.restart();
    const delivered = await Promise.all(retrying);
    const after = await emitVia(running, 4);
    expect({
      whileOpen: whileOpen.error,
      duringRestart: duringRestart.readyz,
      delivered,
      after,
      breaker: (await breakerOf(running)).readyz,
      received: indexer.received.map((r) => (r.body as { at: number }).at).sort(),
    }).toEqual({
      whileOpen: `Webhook 'tick': indexer unreachable at ${indexer.url}, breaker open`,
      duringRestart: { state: "open", consecutiveFailures: expect.any(Number) },
      delivered: [{ ok: true }, { ok: true }],
      after: { ok: true },
      breaker: { state: "closed", consecutiveFailures: 0 },
      received: [1, 2, 4],
    });
  });
});

describe("sidecar runtime: jobs with runOnStart", () => {
  it("runs a runOnStart job once right after start, then on its interval without overlap, and close waits for it", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const gate = deferred();
    cleanups.push(async () => gate.resolve());
    const hourlyRan = deferred();
    const busyStarted = deferred();
    const counts = { hourly: 0, busy: 0, plain: 0 };
    const running = await startSidecar(
      indexer,
      {
        functions: noop,
        jobs: {
          hourly: {
            every: "1h",
            runOnStart: true,
            run: () => {
              counts.hourly++;
              hourlyRan.resolve();
            },
          },
          busy: {
            every: "20ms",
            runOnStart: true,
            run: async ({ emit }) => {
              counts.busy++;
              busyStarted.resolve();
              await gate.promise;
              await emit.tick({ at: 1 }, { chainId: 1 });
            },
          },
          plain: {
            every: "1h",
            run: () => {
              counts.plain++;
            },
          },
        },
      },
      { startJobs: true },
    );
    await Promise.all([hourlyRan.promise, busyStarted.promise]);
    // The busy job holds its start-up run: its interval ticks are skipped, not stacked.
    await new Promise((resolve) => setTimeout(resolve, 120));
    const whileHeld = { ...counts };
    const metrics = await (await fetch(`http://127.0.0.1:${running.internalPort}/metrics`)).text();
    const skipped = Number(/envio_sidecar_job_runs_total\{job="busy",outcome="skipped"\} (\d+)/.exec(metrics)?.[1] ?? 0);
    const closing = running.close({ graceMs: 2_000 });
    setTimeout(() => gate.resolve(), 30);
    const report = await closing;
    expect({ whileHeld, skippedTicks: skipped >= 2, report, ticks: indexer.received.map((r) => r.name) }).toEqual({
      whileHeld: { hourly: 1, busy: 1, plain: 0 },
      skippedTicks: true,
      report: { drained: true, graceMs: 2_000, abandoned: { running: { priceSwap: 0, notify: 0 }, queued: { priceSwap: 0, notify: 0 }, emits: 0, jobs: 0 } },
      ticks: ["tick"],
    });
  });

  it("does not run jobs on start unless asked, and refuses a non-boolean runOnStart", () => {
    expect(() =>
      createSidecar(contract, { functions: noop, jobs: { bad: { every: "1m", runOnStart: "yes" as unknown as boolean, run: () => {} } } }),
    ).toThrow("createSidecar: job 'bad' runOnStart must be true or false");
  });
});

describe("sidecar runtime: close", () => {
  it("stops taking calls, then lets running and queued functions and their emits finish", async () => {
    // The first webhook meets a busy indexer, so the emit is still retrying when close starts.
    const indexer = await fakeIndexer((_received, n) => (n === 1 ? { status: 503 } : undefined));
    cleanups.push(indexer.close);
    const gate = deferred();
    const started = deferred();
    const ranIds: string[] = [];
    const running = await startSidecar(indexer, {
      functions: {
        priceSwap: async ({ input, call, emit }) => {
          started.resolve();
          await gate.promise;
          await emit.swapPriced({ swapId: input.swapId, usd: 1, amount: input.amount });
          ranIds.push(call.id);
        },
        notify: async () => {},
      },
    });
    const base = `http://127.0.0.1:${running.internalPort}`;
    await postJson(`${base}/envio/calls`, {
      batchId: "b-13",
      calls: [
        call("1:100:1:0", "priceSwap", { swapId: "running", amount: "1" }),
        call("1:100:2:0", "priceSwap", { swapId: "queued", amount: "2" }),
      ],
    });
    await started.promise;
    const closing = running.close();
    const duringClose = await Promise.all([
      postJson(`${base}/envio/calls`, { batchId: "b-14", calls: [call("1:101:1:0", "notify", { text: "late" })] }),
      fetch(`${base}/readyz`).then(async (response) => ({ status: response.status, body: (await response.json()) as unknown })),
    ]);
    gate.resolve();
    const report = await closing;
    expect({
      duringClose,
      ranIds,
      received: indexer.received.map((r) => [r.name, r.headers["idempotency-key"]]),
      report,
    }).toEqual({
      duringClose: [
        { status: 503, body: { error: "shutting down" } },
        { status: 503, body: { status: "closing", emitBreaker: { state: "closed", consecutiveFailures: 0 } } },
      ],
      ranIds: ["1:100:1:0", "1:100:2:0"],
      received: [
        ["swapPriced", "1:100:1:0#0"],
        ["swapPriced", "1:100:1:0#0"],
        ["swapPriced", "1:100:2:0#0"],
      ],
      report: {
        drained: true,
        graceMs: 20_000,
        abandoned: { running: { priceSwap: 0, notify: 0 }, queued: { priceSwap: 0, notify: 0 }, emits: 0, jobs: 0 },
      },
    });
  });

  it("gives up on unfinished work after the grace period (ENVIO_SIDECAR_GRACE_MS or close option)", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const gate = deferred();
    cleanups.push(async () => gate.resolve());
    const closeStuck = async (env: NodeJS.ProcessEnv, graceMs?: number) => {
      const started = deferred();
      const ranIds: string[] = [];
      const running = await startSidecar(
        indexer,
        {
          functions: {
            priceSwap: async ({ call }) => {
              ranIds.push(call.id);
              started.resolve();
              await gate.promise;
            },
            notify: async () => {},
          },
        },
        { env },
      );
      await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
        batchId: "b-15",
        calls: [
          call("1:100:1:0", "priceSwap", { swapId: "stuck", amount: "1" }),
          call("1:100:2:0", "priceSwap", { swapId: "never started", amount: "1" }),
        ],
      });
      await started.promise;
      const startedAt = Date.now();
      const report = await running.close(graceMs === undefined ? undefined : { graceMs });
      const elapsed = Date.now() - startedAt;
      return { report, onTime: elapsed >= report.graceMs - 5 && elapsed < report.graceMs + 500, ranIds };
    };
    const outcomes = [await closeStuck({ ENVIO_SIDECAR_GRACE_MS: "50" }), await closeStuck({}, 30)];
    gate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 20));
    const abandoned = {
      running: { priceSwap: 1, notify: 0 },
      queued: { priceSwap: 1, notify: 0 },
      emits: 0,
      jobs: 0,
    };
    expect(outcomes).toEqual([
      { report: { drained: false, graceMs: 50, abandoned }, onTime: true, ranIds: ["1:100:1:0"] },
      { report: { drained: false, graceMs: 30, abandoned }, onTime: true, ranIds: ["1:100:1:0"] },
    ]);
  });
});

describe("sidecar runtime: close with retrying emits", () => {
  it("abandons emits still retrying at the grace cap and reports them", async () => {
    const indexer = await fakeIndexer(() => ({ status: 503 }));
    cleanups.push(indexer.close);
    const started = deferred();
    const outcome = deferred<string>();
    const running = await startSidecar(
      indexer,
      {
        functions: {
          ...noop,
          notify: async ({ emit }) => {
            started.resolve();
            try {
              await emit.tick({ at: 1 });
              outcome.resolve("sent");
            } catch (error) {
              outcome.resolve(error instanceof SidecarEmitError ? error.message : "wrong error");
            }
          },
        },
      },
      // No attempt cap: the budget is the 10 min default, so only close can end it.
      { retry: { baseMs: 5, capMs: 10 } },
    );
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-21",
      calls: [call("1:1:1:0", "notify", { text: "hi" })],
    });
    await started.promise;
    await new Promise((resolve) => setTimeout(resolve, 30));
    const startedAt = Date.now();
    const report = await running.close({ graceMs: 60 });
    const elapsed = Date.now() - startedAt;
    expect({
      report,
      onTime: elapsed < 1_000,
      outcome: await outcome.promise,
      webhooksFailed: running.stats().webhooksFailed,
    }).toEqual({
      report: {
        drained: false,
        graceMs: 60,
        abandoned: { running: { priceSwap: 0, notify: 1 }, queued: { priceSwap: 0, notify: 0 }, emits: 1, jobs: 0 },
      },
      onTime: true,
      outcome: "Webhook 'tick': abandoned: sidecar closed before it was delivered",
      webhooksFailed: 1,
    });
  });
});

describe("sidecar runtime: /metrics", () => {
  it("serves Prometheus text on the internal port: calls, queue, durations, emits, drops, jobs", async () => {
    const indexer = await fakeIndexer((_received, n) => (n === 1 ? { status: 503 } : undefined));
    cleanups.push(indexer.close);
    const gate = deferred();
    cleanups.push(async () => gate.resolve());
    const running = await startSidecar(
      indexer,
      {
        functions: {
          priceSwap: async ({ input, emit }) => {
            await emit.swapPriced({ swapId: input.swapId, usd: 1, amount: input.amount });
          },
          notify: async ({ input }) => {
            if (input.text === "boom") throw new Error("boom");
            if (input.text === "slow") await gate.promise;
          },
        },
      },
      { env: { ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS: "30" }, entry: "src/sidecar.ts" },
    );
    const base = `http://127.0.0.1:${running.internalPort}`;
    await postJson(`${base}/envio/calls`, {
      batchId: "b-22",
      calls: [
        call("1:1:1:0", "priceSwap", { swapId: "s1", amount: "1" }),
        call("1:1:1:0", "priceSwap", { swapId: "s1", amount: "1" }),
        call("1:1:2:0", "notify", { text: "ok" }),
        call("1:1:3:0", "notify", { text: "boom" }),
        call("1:1:4:0", "notify", { text: "slow" }),
        call("1:1:5:0", "nope", { text: "?" }),
      ],
    });
    await running.waitIdle();
    const response = await fetch(`${base}/metrics`);
    const text = await response.text();
    const samples = Object.fromEntries(
      text
        .split("\n")
        .filter((line) => line !== "" && !line.startsWith("#") && !line.includes("_bucket{"))
        .map((line) => {
          const at = line.lastIndexOf(" ");
          return [line.slice(0, at), Number(line.slice(at + 1))];
        }),
    );
    const types = text.split("\n").filter((line) => line.startsWith("# TYPE "));
    expect({
      status: response.status,
      contentType: response.headers.get("content-type"),
      types,
      samples,
    }).toEqual({
      status: 200,
      contentType: "text/plain; version=0.0.4; charset=utf-8",
      types: [
        "# TYPE envio_sidecar_function_calls_total counter",
        "# TYPE envio_sidecar_function_duration_seconds histogram",
        "# TYPE envio_sidecar_function_queue_depth gauge",
        "# TYPE envio_sidecar_function_running gauge",
        "# TYPE envio_sidecar_dropped_total counter",
        "# TYPE envio_sidecar_dedupe_ids gauge",
        "# TYPE envio_sidecar_emit_total counter",
        "# TYPE envio_sidecar_emit_retries_total counter",
        "# TYPE envio_sidecar_emits_pending gauge",
        "# TYPE envio_sidecar_emit_breaker_open gauge",
        "# TYPE envio_sidecar_emit_breaker_opened_total counter",
        "# TYPE envio_sidecar_job_runs_total counter",
        "# TYPE envio_sidecar_job_duration_seconds histogram",
        "# TYPE envio_sidecar_job_last_run_timestamp_seconds gauge",
        "# TYPE envio_sidecar_job_interval_seconds gauge",
        "# TYPE envio_sidecar_ready gauge",
        "# TYPE envio_sidecar_start_time_seconds gauge",
        "# TYPE envio_sidecar_info gauge",
      ],
      samples: {
        'envio_sidecar_function_calls_total{fn="priceSwap",outcome="accepted"}': 1,
        'envio_sidecar_function_calls_total{fn="priceSwap",outcome="duplicate"}': 1,
        'envio_sidecar_function_calls_total{fn="notify",outcome="accepted"}': 3,
        'envio_sidecar_function_calls_total{fn="_unknown",outcome="rejected"}': 1,
        'envio_sidecar_function_calls_total{fn="priceSwap",outcome="succeeded"}': 1,
        'envio_sidecar_function_calls_total{fn="notify",outcome="succeeded"}': 1,
        'envio_sidecar_function_calls_total{fn="notify",outcome="failed"}': 1,
        'envio_sidecar_function_calls_total{fn="notify",outcome="timed_out"}': 1,
        'envio_sidecar_function_duration_seconds_sum{fn="priceSwap"}': expect.any(Number),
        'envio_sidecar_function_duration_seconds_count{fn="priceSwap"}': 1,
        'envio_sidecar_function_duration_seconds_sum{fn="notify"}': expect.any(Number),
        'envio_sidecar_function_duration_seconds_count{fn="notify"}': 3,
        'envio_sidecar_function_queue_depth{fn="priceSwap"}': 0,
        'envio_sidecar_function_queue_depth{fn="notify"}': 0,
        'envio_sidecar_function_running{fn="priceSwap"}': 0,
        'envio_sidecar_function_running{fn="notify"}': 0,
        envio_sidecar_dedupe_ids: 4,
        'envio_sidecar_emit_total{webhook="swapPriced",outcome="sent"}': 1,
        'envio_sidecar_emit_retries_total{webhook="swapPriced"}': 1,
        envio_sidecar_emits_pending: 0,
        envio_sidecar_emit_breaker_open: 0,
        envio_sidecar_ready: 1,
        envio_sidecar_start_time_seconds: expect.any(Number),
        [`envio_sidecar_info{version="${envioVersion}",contract_hash="${sidecarContractHash(contract)}",entry="src/sidecar.ts"}`]: 1,
      },
    });
  });

  it("times jobs: last run per outcome, interval, and the start time", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const before = Date.now() / 1_000;
    const running = await startSidecar(
      indexer,
      {
        functions: noop,
        jobs: {
          ok: { every: "1h", runOnStart: true, run: () => {} },
          bad: {
            every: "5m",
            runOnStart: true,
            run: () => {
              throw new Error("no prices");
            },
          },
          idle: { every: 90_000, run: () => {} },
        },
      },
      { startJobs: true },
    );
    const url = `http://127.0.0.1:${running.internalPort}/metrics`;
    const bothRan = (text: string) => /job="ok",outcome="succeeded"\} /.test(text) && /job="bad",outcome="failed"\} /.test(text);
    let text = await (await fetch(url)).text();
    for (let attempt = 0; attempt < 100 && !bothRan(text); attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      text = await (await fetch(url)).text();
    }
    const after = Date.now() / 1_000;
    const samples = Object.fromEntries(
      text
        .split("\n")
        .filter((line) => /^envio_sidecar_(job_last_run_timestamp_seconds|job_interval_seconds|start_time_seconds)/.test(line))
        .map((line) => {
          const at = line.lastIndexOf(" ");
          const value = Number(line.slice(at + 1));
          return [line.slice(0, at), line.includes("_interval_") ? value : value >= before && value <= after];
        }),
    );
    expect(samples).toEqual({
      'envio_sidecar_job_last_run_timestamp_seconds{job="ok",outcome="succeeded"}': true,
      'envio_sidecar_job_last_run_timestamp_seconds{job="bad",outcome="failed"}': true,
      'envio_sidecar_job_interval_seconds{job="ok"}': 3600,
      'envio_sidecar_job_interval_seconds{job="bad"}': 300,
      'envio_sidecar_job_interval_seconds{job="idle"}': 90,
      envio_sidecar_start_time_seconds: true,
    });
  });
});

describe("sidecar runtime: contract hash", () => {
  it("is the first 16 hex chars of sha256 over the sorted function and webhook type names, blind to declaration order", () => {
    const canonical = JSON.stringify({
      functions: [
        ["notify", "{ text: string; }"],
        ["priceSwap", "{ swapId: string; amount: BigInt; }"],
      ],
      webhooks: [
        ["swapPriced", "{ swapId: string; usd: number; amount: BigInt; }"],
        ["tick", "{ at: number; }"],
      ],
    });
    const reordered = defineSidecar({
      webhooks: {
        tick: { body: { at: S.number } },
        swapPriced: { body: { swapId: S.string, usd: S.number, amount: S.bigint } },
      },
      functions: {
        notify: { input: { text: S.string } },
        priceSwap: { input: { swapId: S.string, amount: S.bigint } },
      },
    });
    const changed = defineSidecar({
      functions: {
        priceSwap: { input: { swapId: S.string, amount: S.string } },
        notify: { input: { text: S.string } },
      },
      webhooks: contract.webhooks,
    });
    expect({
      hash: sidecarContractHash(contract),
      reordered: sidecarContractHash(reordered),
      changed: sidecarContractHash(changed) === sidecarContractHash(contract),
    }).toEqual({
      hash: createHash("sha256").update(canonical).digest("hex").slice(0, 16),
      reordered: createHash("sha256").update(canonical).digest("hex").slice(0, 16),
      changed: false,
    });
  });
});

// Runs one `notify` call and, with `jobs`, each job once, collecting raw log lines.
const logLinesOf = async (
  env: NodeJS.ProcessEnv,
  impl: Partial<SidecarImpl<Contract>> = {},
): Promise<string[]> => {
  const indexer = await fakeIndexer();
  cleanups.push(indexer.close);
  const lines: string[] = [];
  const destination = new Writable({
    write(chunk: Buffer, _encoding, done) {
      for (const line of chunk.toString("utf8").split("\n")) {
        if (line !== "") lines.push(line);
      }
      done();
    },
  });
  const jobsDone = Object.keys(impl.jobs ?? {}).map(() => deferred());
  const jobs = Object.fromEntries(
    Object.entries(impl.jobs ?? {}).map(([name, job], n) => [
      name,
      {
        ...job,
        runOnStart: true,
        run: async (args: Parameters<typeof job.run>[0]) => {
          try {
            await job.run(args);
          } finally {
            jobsDone[n]?.resolve();
          }
        },
      },
    ]),
  );
  const sidecar = createSidecar(contract, { functions: noop, ...impl, jobs });
  const running = await sidecar.start({
    internalPort: 0,
    publicPort: 0,
    indexerInternalUrl: indexer.url,
    env: { ENVIO_EMIT_BREAKER_FAILURES: "0", ...env },
    logDestination: destination,
    startJobs: true,
  });
  await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
    batchId: "b-11",
    calls: [call("1:1:1:0", "notify", { text: "hi" })],
  });
  await running.waitIdle();
  await Promise.all(jobsDone.map((done) => done.promise));
  await running.close();
  return lines;
};

describe("sidecar runtime: log level", () => {
  it("takes ENVIO_SIDECAR_LOG_LEVEL (default info, the pod's LOG_LEVEL ignored), u-levels, and falls back to info on anything else", async () => {
    const notify = ({ log }: { log: { debug: (m: string) => void; info: (m: string) => void; warn: (m: string) => void } }) => {
      log.debug("d");
      log.info("i");
      log.warn("w");
    };
    const cases: Record<string, NodeJS.ProcessEnv> = {
      udebug: { ENVIO_SIDECAR_LOG_LEVEL: "udebug" },
      uinfo: { ENVIO_SIDECAR_LOG_LEVEL: "uinfo" },
      uwarn: { ENVIO_SIDECAR_LOG_LEVEL: "uwarn" },
      uerror: { ENVIO_SIDECAR_LOG_LEVEL: "uerror" },
      debug: { ENVIO_SIDECAR_LOG_LEVEL: "debug" },
      silent: { ENVIO_SIDECAR_LOG_LEVEL: "silent" },
      nonsense: { ENVIO_SIDECAR_LOG_LEVEL: "nonsense" },
      podTraceOnly: { LOG_LEVEL: "trace" },
      sidecarWins: { LOG_LEVEL: "trace", ENVIO_SIDECAR_LOG_LEVEL: "warn" },
    };
    const names = Object.keys(cases);
    const seen = await Promise.all(
      names.map(async (name) =>
        (await logLinesOf(cases[name] ?? {}, { functions: { ...noop, notify } }))
          .map((line) => (JSON.parse(line) as { msg: string }).msg)
          .filter((msg) => ["d", "i", "w"].includes(msg) || msg.startsWith("ENVIO_SIDECAR_LOG_LEVEL")),
      ),
    );
    expect(Object.fromEntries(names.map((name, n) => [name, seen[n]]))).toEqual({
      udebug: ["d", "i", "w"],
      uinfo: ["i", "w"],
      uwarn: ["w"],
      uerror: [],
      debug: ["d", "i", "w"],
      silent: [],
      nonsense: ["ENVIO_SIDECAR_LOG_LEVEL 'nonsense' is not a known level, using 'info'", "i", "w"],
      podTraceOnly: ["i", "w"],
      sidecarWins: ["w"],
    });
  });
});

// What Alloy's `id-pods` pipeline (k8s charts/global/alloy/configs/id-pods.alloy)
// does with a container line: `stage.json` with the JMESPath expressions
// `"@timestamp"`, `"ecs.version"` and `"log.level"` (quoted, so literal top
// level keys, not nested paths), then templates that default a missing
// ecsVersion to 1.6.0 and a missing level to `stdout`.
const alloyIdPods = (line: string) => {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  const ecsVersion = parsed["ecs.version"];
  const logLevel = parsed["log.level"];
  return {
    labels: {
      ecsVersion: typeof ecsVersion === "string" && ecsVersion !== "" ? ecsVersion : "1.6.0",
      level: typeof logLevel === "string" && logLevel !== "" ? logLevel : "stdout",
    },
    parsed,
  };
};

describe("sidecar runtime: ECS logs under LOG_STRATEGY=ecs-*", () => {
  it("writes ECS JSON that the id-pods Alloy pipeline labels by level, with fn, callId, chainId and job kept", async () => {
    const lines = await logLinesOf(
      { LOG_STRATEGY: "ecs-console", LOG_LEVEL: "trace", ENVIO_SIDECAR_LOG_LEVEL: "debug" },
      {
        functions: {
          ...noop,
          notify: ({ log }) => {
            log.debug("pricing", { swaps: 2 });
            log.error("price feed down", new Error("boom"));
          },
        },
        jobs: {
          sweep: {
            every: "1h",
            run: ({ log }) => {
              log.warn("swept", { stale: 3 });
            },
          },
        },
      },
    );
    const parsed = lines.map(alloyIdPods);
    const byMessage = (message: string) => parsed.find((line) => line.parsed.message === message);
    const isoTimestamp = expect.stringMatching(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    expect({
      everyLineLabelled: parsed.every(
        ({ labels, parsed }) => labels.level !== "stdout" && parsed["ecs.version"] === "1.6.0" && !("level" in parsed) && !("msg" in parsed),
      ),
      pricing: byMessage("pricing"),
      failed: byMessage("price feed down"),
      swept: byMessage("swept"),
      started: byMessage("sidecar started")?.labels,
    }).toEqual({
      everyLineLabelled: true,
      pricing: {
        labels: { ecsVersion: "1.6.0", level: "debug" },
        parsed: {
          "@timestamp": isoTimestamp,
          "log.level": "debug",
          "ecs.version": "1.6.0",
          fn: "notify",
          callId: "1:1:1:0",
          chainId: 1,
          swaps: 2,
          message: "pricing",
        },
      },
      failed: {
        labels: { ecsVersion: "1.6.0", level: "error" },
        parsed: {
          "@timestamp": isoTimestamp,
          "log.level": "error",
          "ecs.version": "1.6.0",
          fn: "notify",
          callId: "1:1:1:0",
          chainId: 1,
          error: { type: "Error", message: "boom", stack_trace: expect.stringContaining("Error: boom") },
          message: "price feed down",
        },
      },
      swept: {
        labels: { ecsVersion: "1.6.0", level: "warn" },
        parsed: {
          "@timestamp": isoTimestamp,
          "log.level": "warn",
          "ecs.version": "1.6.0",
          job: "sweep",
          stale: 3,
          message: "swept",
        },
      },
      started: { ecsVersion: "1.6.0", level: "info" },
    });
  });

  it("keeps plain pino JSON under any other LOG_STRATEGY", async () => {
    const lines = await logLinesOf({ LOG_STRATEGY: "console-pretty" });
    const started = lines.map((line) => JSON.parse(line) as Record<string, unknown>).find((line) => line.msg === "sidecar started");
    expect({ level: started?.level, labels: started === undefined ? undefined : alloyIdPods(JSON.stringify(started)).labels }).toEqual({
      level: 30,
      labels: { ecsVersion: "1.6.0", level: "stdout" },
    });
  });
});

describe("sidecar runtime: public server", () => {
  it("serves user routes with the read client and emit attached, probes, and async errors", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const running = await startSidecar(indexer, {
      functions: noop,
      routes: (app) => {
        app.get("/top", async (req, res) => {
          res.json({ ok: true, x: req.query.x, hasIndexer: typeof app.indexer.query === "function" });
        });
        app.post("/hooks/external", async (req, res) => {
          const body = req.body as { at: number };
          await app.emit.tick({ at: body.at }, { chainId: 1 });
          res.status(204).end();
        });
        app.get("/boom", async () => {
          throw new Error("boom");
        });
      },
    });
    const pub = `http://127.0.0.1:${running.publicPort}`;
    const internal = `http://127.0.0.1:${running.internalPort}`;
    const get = async (url: string) => {
      const response = await fetch(url);
      return { status: response.status, body: (await response.json()) as unknown };
    };
    const [top, hook, boom, pubHealth, health, ready] = await Promise.all([
      get(`${pub}/top?x=1`),
      postJson(`${pub}/hooks/external`, { at: 42 }),
      get(`${pub}/boom`),
      get(`${pub}/healthz`),
      get(`${internal}/healthz`),
      get(`${internal}/readyz`),
    ]);
    expect({ top, hook, boom, pubHealth, health, ready, received: indexer.received.map((r) => [r.name, r.body]) }).toEqual({
      top: { status: 200, body: { ok: true, x: "1", hasIndexer: true } },
      hook: { status: 204, body: undefined },
      boom: { status: 500, body: { error: "internal error" } },
      pubHealth: { status: 200, body: { status: "ok" } },
      health: { status: 200, body: { status: "ok" } },
      ready: { status: 200, body: { status: "ok", emitBreaker: { state: "closed", consecutiveFailures: 0 } } },
      received: [["tick", { at: 42 }]],
    });
  });

  it("refuses a sidecar that does not implement its contract", () => {
    const outcomes = [
      () => createSidecar(contract, { functions: { priceSwap: async () => {} } } as never),
      () => createSidecar(contract, { functions: { ...noop, extra: async () => {} } } as never),
      () => createSidecar({ functions: {} } as never, { functions: {} }),
      () => createSidecar(contract, { functions: noop, jobs: { j: { every: "5x", run: async () => {} } } }),
      () => createSidecar(contract, { functions: { ...noop, notify: { timeout: "soon", run: async () => {} } } }),
    ].map((make) => {
      try {
        make();
        return "no error";
      } catch (error) {
        return error instanceof Error ? error.message : "wrong error";
      }
    });
    expect(outcomes).toEqual([
      "createSidecar: function 'notify' is in the contract but not implemented",
      "createSidecar: function 'extra' is implemented but not in the contract",
      "createSidecar: first argument must come from defineSidecar(...)",
      'Job interval \'5x\' is not like "30s", "5m", "1h" or a number of ms',
      'createSidecar: function \'notify\' timeout \'soon\' is not like "30s", "5m" or a number of ms',
    ]);
  });
});

// The suite's own Postgres; the handle refuses writes whoever it logs in as.
const sqlEnv = {
  ENVIO_SIDECAR_PG_HOST: process.env.ENVIO_PG_HOST ?? "localhost",
  ENVIO_SIDECAR_PG_PORT: process.env.ENVIO_PG_PORT ?? "5433",
  ENVIO_SIDECAR_PG_DATABASE: process.env.ENVIO_PG_DATABASE ?? "envio-dev",
  ENVIO_SIDECAR_PG_USER: process.env.ENVIO_PG_USER ?? "postgres",
  ENVIO_SIDECAR_PG_PASSWORD: process.env.ENVIO_PG_PASSWORD ?? "testing",
};

const rejection = async (promise: Promise<unknown>) => {
  try {
    await promise;
    return "resolved";
  } catch (error) {
    return error;
  }
};

describe("sidecar runtime: sql", () => {
  it("hands sql from ENVIO_SIDECAR_PG_* to functions, jobs and routes, counts it on /metrics, and ends it on close", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const seen: Record<string, unknown> = {};
    const jobRan = deferred();
    let captured: SidecarSql | undefined;
    const running = await startSidecar(
      indexer,
      {
        functions: {
          ...noop,
          priceSwap: async ({ input, sql }) => {
            captured = sql;
            seen.function = [...(await sql<{ id: string }[]>`select ${input.swapId}::text as id`)];
          },
        },
        jobs: {
          snapshot: {
            every: "1h",
            runOnStart: true,
            run: async ({ sql }) => {
              seen.job = [...(await sql.transaction(async (tx) => tx`select 2 as n`))];
              jobRan.resolve();
            },
          },
        },
        routes: (app) => {
          app.get("/n", async (_req, res) => {
            res.json({ rows: await app.sql`select 3 as n`, enabled: app.sql.enabled, schema: app.sql.schema });
          });
        },
      },
      { startJobs: true, env: { ...process.env, ...sqlEnv } },
    );
    await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
      batchId: "b-sql",
      calls: [call("1:100:1:0", "priceSwap", { swapId: "s1", amount: "1" })],
    });
    await running.waitIdle();
    await jobRan.promise;
    seen.route = await (await fetch(`http://127.0.0.1:${running.publicPort}/n`)).json();
    const metrics = await (await fetch(`http://127.0.0.1:${running.internalPort}/metrics`)).text();
    await running.close();
    const afterClose = await rejection((captured as SidecarSql)`select 1`);
    expect({
      seen,
      metrics: metrics.split("\n").filter((line) => /^envio_sidecar_sql_(queries_total|pool_in_use|query_seconds_count)/.test(line)),
      afterClose,
    }).toEqual({
      seen: {
        function: [{ id: "s1" }],
        job: [{ n: 2 }],
        route: { rows: [{ n: 3 }], enabled: true, schema: "public" },
      },
      metrics: [
        'envio_sidecar_sql_queries_total{outcome="ok"} 3',
        "envio_sidecar_sql_query_seconds_count 3",
        "envio_sidecar_sql_pool_in_use 0",
      ],
      afterClose: expect.objectContaining({ name: "SidecarSqlError", code: "QUERY_FAILED" }),
    });
  });

  it("starts without ENVIO_SIDECAR_PG_* (sql then rejects with SidecarSqlDisabledError) and uses an injected handle as is", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const outcomes: unknown[] = [];
    const impl: SidecarImpl<Contract> = {
      functions: {
        ...noop,
        priceSwap: async ({ sql }) => {
          outcomes.push(sql.enabled ? [...(await sql`select 1 as n`)] : await rejection(sql`select 1`));
        },
      },
    };
    const send = async (running: RunningSidecar, id: string) => {
      await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
        batchId: id,
        calls: [call(id, "priceSwap", { swapId: "s", amount: "1" })],
      });
      await running.waitIdle();
    };
    const disabled = await startSidecar(indexer, impl, { env: {} });
    await send(disabled, "1:1:1:0");

    const injected = createSidecarSql(readEnv(sqlEnv).sql);
    cleanups.push(() => injected.end(1_000));
    const withInjected = await createSidecar(contract, impl).start({
      internalPort: 0,
      publicPort: 0,
      indexerInternalUrl: indexer.url,
      logLevel: "silent",
      env: {},
      sql: injected,
    });
    await send(withInjected, "1:1:2:0");
    await withInjected.close();
    expect({
      disabled: outcomes[0] instanceof SidecarSqlDisabledError,
      injected: outcomes[1],
      stillOpen: [...(await injected`select 4 as n`)],
    }).toEqual({ disabled: true, injected: [{ n: 1 }], stillOpen: [{ n: 4 }] });
  });
});
