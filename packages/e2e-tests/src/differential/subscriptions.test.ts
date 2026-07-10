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
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";

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

      // The graphql-transport-ws spec pins connection-level misuse to
      // specific close codes (4409/4401/4429); the legacy protocol has no
      // equivalent mandated behavior, so these three run only for the
      // modern protocol. Hasura is the runtime oracle either way.
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

          const hasura = await run(endpoints.hasura);
          const envio = await run(endpoints.envio);
          expect(envio).toEqual(hasura);
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

          const hasura = await run(endpoints.hasura);
          const envio = await run(endpoints.envio);
          expect(envio).toEqual(hasura);
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

          const hasura = await run(endpoints.hasura);
          const envio = await run(endpoints.envio);
          expect(envio).toEqual(hasura);
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
});
