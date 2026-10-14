import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { Writable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { defineSidecar, S } from "envio";
import { createSidecar, SidecarEmitError, type RetryPolicy, type RunningSidecar, type SidecarImpl } from "envio/sidecar";

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
  return {
    url: `http://127.0.0.1:${address.port}`,
    received,
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
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
  options: { startJobs?: boolean; env?: NodeJS.ProcessEnv; retry?: RetryPolicy } = {},
): Promise<RunningSidecar> => {
  const sidecar = createSidecar(contract, impl);
  const running = await sidecar.start({
    internalPort: 0,
    publicPort: 0,
    indexerInternalUrl: indexer.url,
    logLevel: "silent",
    retry: options.retry ?? { attempts: 4, baseMs: 1, capMs: 5 },
    startJobs: options.startJobs ?? false,
    ...(options.env === undefined ? {} : { env: options.env }),
  });
  cleanups.push(running.close);
  return running;
};

const noop = { priceSwap: async () => {}, notify: async () => {} };

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
        { status: 503, body: { status: "closing" } },
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
      { env: { ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS: "30" } },
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
        "# TYPE envio_sidecar_job_runs_total counter",
        "# TYPE envio_sidecar_job_duration_seconds histogram",
        "# TYPE envio_sidecar_ready gauge",
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
        envio_sidecar_ready: 1,
      },
    });
  });
});

describe("sidecar runtime: LOG_LEVEL", () => {
  it("accepts the indexer's u-levels and falls back to info on anything else", async () => {
    const indexer = await fakeIndexer();
    cleanups.push(indexer.close);
    const linesAt = async (level: string) => {
      const lines: Array<{ level: number; msg: string }> = [];
      const destination = new Writable({
        write(chunk: Buffer, _encoding, done) {
          for (const line of chunk.toString("utf8").split("\n")) {
            if (line !== "") lines.push(JSON.parse(line) as { level: number; msg: string });
          }
          done();
        },
      });
      const sidecar = createSidecar(contract, {
        functions: {
          ...noop,
          notify: ({ log }) => {
            log.debug("d");
            log.info("i");
            log.warn("w");
          },
        },
      });
      const running = await sidecar.start({
        internalPort: 0,
        publicPort: 0,
        indexerInternalUrl: indexer.url,
        env: { LOG_LEVEL: level },
        logDestination: destination,
        startJobs: false,
      });
      await postJson(`http://127.0.0.1:${running.internalPort}/envio/calls`, {
        batchId: "b-11",
        calls: [call("1:1:1:0", "notify", { text: "hi" })],
      });
      await running.waitIdle();
      await running.close();
      return lines.filter((line) => ["d", "i", "w"].includes(line.msg) || line.msg.startsWith("LOG_LEVEL")).map((line) => line.msg);
    };
    const levels = ["udebug", "uinfo", "uwarn", "uerror", "debug", "silent", "nonsense"];
    const seen = await Promise.all(levels.map(linesAt));
    expect(Object.fromEntries(levels.map((level, n) => [level, seen[n]]))).toEqual({
      udebug: ["d", "i", "w"],
      uinfo: ["i", "w"],
      uwarn: ["w"],
      uerror: [],
      debug: ["d", "i", "w"],
      silent: [],
      nonsense: ["LOG_LEVEL 'nonsense' is not a known level, using 'info'", "i", "w"],
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
      ready: { status: 200, body: { status: "ok" } },
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
