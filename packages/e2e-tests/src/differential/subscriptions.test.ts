/**
 * Differential WebSocket subscription suite: identical scenarios executed
 * against real Hasura and `envio serve`, comparing payloads frame-by-frame
 * (timing-insensitive: only order and content of data payloads matter).
 *
 * Covers both subprotocols Hasura serves on /v1/graphql.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { applyFixture, trackDatabase, runSql } from "./hasuraSetup.js";
import { phaseConfigs } from "./corpus.js";
import { adminSecret, hasuraPort, servePort } from "./env.js";
import { connect, subscribe, type WsProtocol } from "./wsClient.js";
import {
  spawnServe,
  startServe,
  stopServe,
  waitForServeExit,
  type ServeProcess,
} from "./serveProcess.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

const endpoints = {
  hasura: `ws://localhost:${hasuraPort}/v1/graphql`,
  envio: `ws://localhost:${servePort}/v1/graphql`,
};

const protocols: WsProtocol[] = ["graphql-transport-ws", "graphql-ws"];

interface ScenarioResult {
  payloads: unknown[];
  errorPayload?: unknown;
}

describe.sequential("differential subscriptions", () => {
  let serve: ServeProcess;

  beforeAll(async () => {
    await applyFixture(fixtureDir);
    await trackDatabase(phaseConfigs.default);
    serve = await startServe(phaseConfigs.default);
  }, 180_000);

  afterAll(async () => {
    await stopServe(serve);
  });

  for (const protocol of protocols) {
    describe.sequential(protocol, () => {
      it("live query: initial payload, update on insert, stop", async () => {
        const query = `subscription { SimpleEntity(order_by: {id: asc}, where: {id: {_like: "sub-tmp%"}}) { id value } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const payloads: unknown[] = [];
          try {
            const sub = subscribe(session, protocol, { query });
            payloads.push(await sub.nextData());
            await runSql(
              `INSERT INTO public."SimpleEntity" (id, value) VALUES ('sub-tmp-1', 'live');`
            );
            payloads.push(await sub.nextData());
            session.assertNoUnconsumedData();
            sub.stop();
          } finally {
            await session.close();
            await runSql(`DELETE FROM public."SimpleEntity" WHERE id LIKE 'sub-tmp%';`);
          }
          return { payloads };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it("by_pk subscription with variables", async () => {
        const query = `subscription ($id: String!) { User_by_pk(id: $id) { id updatesCountOnUserForTesting } }`;
        const variables = { id: "user-1" };

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const payloads: unknown[] = [];
          try {
            const sub = subscribe(session, protocol, { query, variables });
            payloads.push(await sub.nextData());
            await runSql(
              `UPDATE public."User" SET "updatesCountOnUserForTesting" = 777 WHERE id = 'user-1';`
            );
            payloads.push(await sub.nextData());
            session.assertNoUnconsumedData();
            sub.stop();
          } finally {
            await session.close();
            await runSql(
              `UPDATE public."User" SET "updatesCountOnUserForTesting" = 0 WHERE id = 'user-1';`
            );
          }
          return { payloads };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it("query over websocket completes after one payload", async () => {
        const query = `{ SimpleEntity(order_by: {id: asc}, limit: 2) { id value } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          try {
            const sub = subscribe(session, protocol, { query });
            const first = await sub.nextData();
            await sub.waitComplete();
            session.assertNoUnconsumedData();
            return { payloads: [first] };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 60_000);

      it("validation error surfaces as protocol error frame", async () => {
        const query = `subscription { NotATable { id } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          try {
            const sub = subscribe(session, protocol, { query });
            const errorPayload = await sub.nextError();
            return { payloads: [], errorPayload };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.errorPayload).toEqual(hasura.errorPayload);
      }, 60_000);

      it("public role subscription is limited to public schema", async () => {
        const query = `subscription { User_aggregate { aggregate { count } } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, {});
          try {
            const sub = subscribe(session, protocol, { query });
            const errorPayload = await sub.nextError();
            return { payloads: [], errorPayload };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.errorPayload).toEqual(hasura.errorPayload);
      }, 60_000);

      it("streaming subscription advances the cursor", async () => {
        const query = `subscription { SimulateTestEvent_stream(batch_size: 2, cursor: {initial_value: {blockNumber: 0}, ordering: ASC}) { id blockNumber logIndex } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const payloads: unknown[] = [];
          try {
            const sub = subscribe(session, protocol, { query });
            payloads.push(await sub.nextData());
            payloads.push(await sub.nextData());
            payloads.push(await sub.nextData());
            session.assertNoUnconsumedData();
            sub.stop();
          } finally {
            await session.close();
          }
          return { payloads };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it("streaming subscription preserves an explicit NULL cursor boundary", async () => {
        const query = `subscription { User_stream(batch_size: 2, cursor: {initial_value: {gravatar_id: null}, ordering: DESC}) { id gravatar_id } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          try {
            const sub = subscribe(session, protocol, { query });
            // Hasura keeps explicit NULL as the cursor value. The resulting
            // strict SQL comparison matches no rows, so no batch is emitted.
            // Waiting across two poll intervals distinguishes this from the
            // old behavior, which dropped NULL and streamed unbounded rows.
            await new Promise((resolve) => setTimeout(resolve, 2_500));
            session.assertNoUnconsumedData();
            sub.stop();
          } finally {
            await session.close();
          }
          return { payloads: [] };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it("query variables preserve numbers outside f64 range", async () => {
        const query = `query ($n: numeric!, $j: jsonb!) { numeric: Token(where: {tokenId: {_eq: $n}}, order_by: {id: asc}) { id } json: EntityWithAllTypes(where: {json: {_contains: $j}}, order_by: {id: asc}) { id } }`;
        const rawVariables = `{"n":1e400,"j":{"nested":-9e999}}`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const id = "overflow-vars";
          const startType = protocol === "graphql-transport-ws" ? "subscribe" : "start";
          const dataType = protocol === "graphql-transport-ws" ? "next" : "data";
          try {
            session.sendRaw(
              `{"type":${JSON.stringify(startType)},"id":${JSON.stringify(id)},"payload":{"query":${JSON.stringify(query)},"variables":${rawVariables}}}`
            );
            const frame = await session.next(
              (candidate) =>
                candidate.id === id &&
                (candidate.type === dataType || candidate.type === "error")
            );
            if (frame.type === "error") {
              return { payloads: [], errorPayload: frame.payload };
            }
            await session.next(
              (candidate) => candidate.id === id && candidate.type === "complete"
            );
            return { payloads: [frame.payload] };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio).toEqual(hasura);
      }, 60_000);

      it("streaming subscription loses rows tied with the cursor boundary", async () => {
        // Hasura's single-column stream cursor has no tie-breaking: with
        // batch_size 1, sim-1 and sim-2 both have blockNumber 100. Batch 1
        // returns only sim-1 (arbitrary pick among ties); the cursor then
        // advances to blockNumber=100 and the next query's strict `> 100`
        // bound permanently skips sim-2. This is real, observed Hasura
        // v2.43.0 behavior (verified live) — not an idealized "WITH TIES"
        // protection — and envio serve must reproduce it exactly rather
        // than "fix" it.
        const query = `subscription { SimulateTestEvent_stream(batch_size: 1, cursor: {initial_value: {blockNumber: 0}, ordering: ASC}) { id blockNumber } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const payloads: unknown[] = [];
          try {
            const sub = subscribe(session, protocol, { query });
            payloads.push(await sub.nextData());
            payloads.push(await sub.nextData());
            payloads.push(await sub.nextData());
            session.assertNoUnconsumedData();
            sub.stop();
          } finally {
            await session.close();
          }
          return { payloads };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it.each([
        ["cursor: []", "[]"],
        ["cursor: [null]", "[null]"],
      ])(
        "streaming subscription rejects an empty cursor (%s)",
        async (_label, cursorLiteral) => {
          const query = `subscription { SimulateTestEvent_stream(batch_size: 2, cursor: ${cursorLiteral}) { id blockNumber } }`;

          const run = async (url: string): Promise<ScenarioResult> => {
            const session = await connect(url, protocol, { adminSecret });
            try {
              const sub = subscribe(session, protocol, { query });
              const errorPayload = await sub.nextError();
              return { payloads: [], errorPayload };
            } finally {
              await session.close();
            }
          };

          const hasura = await run(endpoints.hasura);
          const envio = await run(endpoints.envio);
          expect(envio.errorPayload).toEqual(hasura.errorPayload);
        },
        60_000
      );

      it("streaming subscription rejects a null cursor", async () => {
        const query = `subscription { SimulateTestEvent_stream(batch_size: 2, cursor: null) { id blockNumber } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          try {
            const sub = subscribe(session, protocol, { query });
            const errorPayload = await sub.nextError();
            return { payloads: [], errorPayload };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.errorPayload).toEqual(hasura.errorPayload);
      }, 60_000);

      // Functional GraphQL behavior is diffed against Hasura above. For
      // connection-level misuse, graphql-transport-ws itself is the oracle:
      // it mandates 4409/4401/4429, while Hasura v2.43 closes normally or
      // accepts a repeated init. The legacy protocol has no equivalent
      // mandated behavior, so these run only for the modern protocol.
      if (protocol === "graphql-transport-ws") {
        it("duplicate subscription id on one socket closes with 4409", async () => {
          const query = `subscription { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }`;

          const run = async (url: string): Promise<number> => {
            const session = await connect(url, protocol, { adminSecret });
            try {
              const sub = subscribe(session, protocol, { query }, "dup-id");
              await sub.nextData();
              subscribe(session, protocol, { query }, "dup-id");
              return (await session.waitClose()).code;
            } finally {
              await session.close();
            }
          };

          const envio = await run(endpoints.envio);
          expect(envio).toBe(4409);
        }, 60_000);

        it("subscribe before connection_init closes with 4401", async () => {
          const query = `subscription { SimpleEntity(limit: 1) { id } }`;

          const run = async (url: string): Promise<number> => {
            const session = await connect(url, protocol, { skipInit: true });
            try {
              session.send({ type: "subscribe", id: "1", payload: { query } });
              return (await session.waitClose()).code;
            } finally {
              await session.close();
            }
          };

          const envio = await run(endpoints.envio);
          expect(envio).toBe(4401);
        }, 60_000);

        it("second connection_init closes with 4429", async () => {
          const run = async (url: string): Promise<number> => {
            const session = await connect(url, protocol, { adminSecret });
            try {
              session.send({ type: "connection_init", payload: {} });
              return (await session.waitClose()).code;
            } finally {
              await session.close();
            }
          };

          const envio = await run(endpoints.envio);
          expect(envio).toBe(4429);
        }, 60_000);
      }

      it("concurrent subscriptions on one socket receive independent updates", async () => {
        const queryFor = (prefix: string) =>
          `subscription { SimpleEntity(order_by: {id: asc}, where: {id: {_like: "${prefix}%"}}) { id value } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          const session = await connect(url, protocol, { adminSecret });
          const payloads: unknown[] = [];
          try {
            const subA = subscribe(session, protocol, { query: queryFor("multi-a") });
            const subB = subscribe(session, protocol, { query: queryFor("multi-b") });
            payloads.push(await subA.nextData());
            payloads.push(await subB.nextData());
            await runSql(
              `INSERT INTO public."SimpleEntity" (id, value) VALUES ('multi-a-1', 'a');`
            );
            payloads.push(await subA.nextData());
            await runSql(
              `INSERT INTO public."SimpleEntity" (id, value) VALUES ('multi-b-1', 'b');`
            );
            payloads.push(await subB.nextData());
            // A spurious extra push on either subscription (e.g. sub B
            // reacting to sub A's row) is exactly what this scenario must
            // catch.
            session.assertNoUnconsumedData();
            subA.stop();
            subB.stop();
          } finally {
            await session.close();
            await runSql(`DELETE FROM public."SimpleEntity" WHERE id LIKE 'multi-%';`);
          }
          return { payloads };
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);

      it("rapid connect/disconnect churn leaves the server healthy", async () => {
        const query = `subscription { SimpleEntity(order_by: {id: asc}, limit: 1) { id value } }`;

        const run = async (url: string): Promise<ScenarioResult> => {
          for (let i = 0; i < 5; i++) {
            const session = await connect(url, protocol, { adminSecret });
            subscribe(session, protocol, { query });
            await session.close();
          }
          const session = await connect(url, protocol, { adminSecret });
          try {
            const sub = subscribe(session, protocol, { query });
            const payload = await sub.nextData();
            session.assertNoUnconsumedData();
            sub.stop();
            return { payloads: [payload] };
          } finally {
            await session.close();
          }
        };

        const hasura = await run(endpoints.hasura);
        const envio = await run(endpoints.envio);
        expect(envio.payloads).toEqual(hasura.payloads);
      }, 90_000);
    });
  }

  it("reports actionable PostgreSQL startup errors", async () => {
    const failed = spawnServe(phaseConfigs.default, servePort + 1, {
      ENVIO_PG_PORT: "1",
      ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS: "0",
    });
    try {
      const exit = await waitForServeExit(failed, 15_000);
      const output = failed.logs.join("");
      expect(exit).toEqual({ code: 1, signal: null });
      expect(output).toContain("Cannot connect to PostgreSQL");
      expect(output).toContain("localhost:1/envio-dev");
      expect(output).toContain("Make sure PostgreSQL is running");
      expect(output).toContain("ENVIO_PG_HOST");
      expect(output).toContain("ENVIO_PG_PORT");
      expect(output).toContain("ENVIO_PG_DATABASE");
    } finally {
      if (failed.child.exitCode === null) failed.child.kill("SIGKILL");
    }
  }, 30_000);

  it("reports an actionable error when the serve port is already in use", async () => {
    const conflict = spawnServe(phaseConfigs.default);
    try {
      const exit = await waitForServeExit(conflict, 15_000);
      const output = conflict.logs.join("");
      expect(exit).toEqual({ code: 1, signal: null });
      expect(output).toContain(`Port ${servePort} is already in use`);
      expect(output).toContain(`lsof -ti :${servePort} | xargs kill`);
      expect(output).toContain(`envio serve --port ${servePort + 1}`);
      expect(output).toContain(`ENVIO_SERVE_PORT=${servePort + 1}`);
    } finally {
      if (conflict.child.exitCode === null) conflict.child.kill("SIGKILL");
    }
  }, 30_000);

  it.runIf(process.platform !== "win32")(
    "returns control to the console after Ctrl-C",
    async () => {
      expect(serve.child.exitCode).toBeNull();
      try {
        expect(serve.child.kill("SIGINT")).toBe(true);
        await expect(waitForServeExit(serve, 5_000)).resolves.toEqual({
          code: 0,
          signal: null,
        });
      } finally {
        if (serve.child.exitCode === null) serve.child.kill("SIGKILL");
      }
    },
    15_000
  );
});
