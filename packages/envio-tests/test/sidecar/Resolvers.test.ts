import { createServer } from "node:http";
import { Writable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { defineSidecar, S } from "envio";
import {
  applyResolverMetadata,
  buildResolverMetadata,
  createSidecar,
  RESOLVER_SECRET_HEADER,
  ResolverError,
  type RunningSidecar,
  type SidecarImpl,
} from "envio/sidecar";

const resolvers = {
  topTraders: {
    description: "Top traders by volume",
    args: { limit: "Int!", chainId: "Int" },
    output: "[TopTrader!]!",
    handler: "sidecar",
    timeoutMs: 2500,
  },
  tokenMeta: {
    args: { address: "String!" },
    output: "TokenMeta",
    handler: "https://api.example.com/envio/tokenMeta",
    timeoutMs: 30000,
  },
};

const types = {
  TopTrader: { address: "String!", volume: "BigInt!", rank: "Int!" },
  TokenMeta: { name: "String", price: "BigDecimal" },
};

describe("buildResolverMetadata", () => {
  it("renders Hasura actions and custom types, sidecar handlers under the given URL", () => {
    expect(
      buildResolverMetadata(resolvers, types, {
        sidecarUrl: "http://id-abc:9900/",
        secret: { value: "s3cret" },
      }),
    ).toEqual({
      actions: [
        {
          name: "tokenMeta",
          definition: {
            type: "query",
            kind: "synchronous",
            handler: "https://api.example.com/envio/tokenMeta",
            arguments: [{ name: "address", type: "String!" }],
            output_type: "TokenMeta",
            timeout: 30,
            headers: [{ name: RESOLVER_SECRET_HEADER, value: "s3cret" }],
          },
          permissions: [{ role: "public" }],
        },
        {
          name: "topTraders",
          comment: "Top traders by volume",
          definition: {
            type: "query",
            kind: "synchronous",
            handler: "http://id-abc:9900/resolvers/topTraders",
            arguments: [
              { name: "chainId", type: "Int" },
              { name: "limit", type: "Int!" },
            ],
            output_type: "[TopTrader!]!",
            timeout: 3,
            headers: [{ name: RESOLVER_SECRET_HEADER, value: "s3cret" }],
          },
          permissions: [{ role: "public" }],
        },
      ],
      custom_types: {
        scalars: [{ name: "BigDecimal" }, { name: "BigInt" }],
        enums: [],
        input_objects: [],
        objects: [
          {
            name: "TokenMeta",
            fields: [
              { name: "name", type: "String" },
              { name: "price", type: "BigDecimal" },
            ],
          },
          {
            name: "TopTrader",
            fields: [
              { name: "address", type: "String!" },
              { name: "rank", type: "Int!" },
              { name: "volume", type: "BigInt!" },
            ],
          },
        ],
      },
    });
  });

  it("can read the secret and the sidecar URL from serve's environment instead", () => {
    const metadata = buildResolverMetadata({ topTraders: resolvers.topTraders }, types, {
      sidecarUrl: "{{ENVIO_SIDECAR_RESOLVERS_URL}}",
      secret: { fromEnv: "ENVIO_RESOLVER_SECRET" },
    });
    expect(metadata.actions.map((a) => [a.definition.handler, a.definition.headers])).toEqual([
      [
        "{{ENVIO_SIDECAR_RESOLVERS_URL}}/resolvers/topTraders",
        [{ name: RESOLVER_SECRET_HEADER, value_from_env: "ENVIO_RESOLVER_SECRET" }],
      ],
    ]);
  });

  it("puts a kind: mutation resolver under the mutation root, and defaults to query", () => {
    const metadata = buildResolverMetadata(
      {
        sendTip: { kind: "mutation", args: { to: "[String!]!" }, output: "TipResult!", handler: "sidecar", timeoutMs: 5000 },
        wallet: { kind: "query", args: {}, output: "String", handler: "sidecar", timeoutMs: 5000 },
        topTraders: resolvers.topTraders,
      },
      { TipResult: { id: "String!", recipients: "[String!]!" } },
      { sidecarUrl: "http://sc:9900" },
    );
    expect(metadata.actions.map((a) => [a.name, a.definition.type, a.definition.kind])).toEqual([
      ["sendTip", "mutation", "synchronous"],
      ["topTraders", "query", "synchronous"],
      ["wallet", "query", "synchronous"],
    ]);
  });

  it("sends no secret header without a secret", () => {
    const metadata = buildResolverMetadata({ topTraders: resolvers.topTraders }, types, {
      sidecarUrl: "http://localhost:9900",
    });
    expect(metadata.actions[0]?.definition.headers).toBeUndefined();
  });
});

describe("applyResolverMetadata", () => {
  it("applies everything in one bulk call to the metadata API", async () => {
    const calls: Array<{ url: string; headers: Record<string, string>; body: unknown }> = [];
    const fetch = (async (url: string, init: RequestInit) => {
      calls.push({ url, headers: init.headers as Record<string, string>, body: JSON.parse(init.body as string) });
      return new Response(JSON.stringify([{ message: "success" }]), { status: 200 });
    }) as typeof globalThis.fetch;
    const metadata = buildResolverMetadata({ topTraders: resolvers.topTraders }, types, {
      sidecarUrl: "http://sc:9900",
    });

    await applyResolverMetadata({
      endpoint: "http://hasura:8080/v1/metadata",
      role: "admin",
      adminSecret: "testing",
      metadata,
      fetch,
    });

    expect(calls).toEqual([
      {
        url: "http://hasura:8080/v1/metadata",
        headers: {
          "content-type": "application/json",
          "x-hasura-role": "admin",
          "x-hasura-admin-secret": "testing",
        },
        body: {
          type: "bulk",
          args: [
            { type: "set_custom_types", args: metadata.custom_types },
            {
              type: "create_action",
              args: { name: "topTraders", comment: "Top traders by volume", definition: metadata.actions[0]?.definition },
            },
            { type: "create_action_permission", args: { action: "topTraders", role: "public" } },
          ],
        },
      },
    ]);
  });

  it("makes no call when nothing is declared", async () => {
    let called = false;
    const fetch = (async () => {
      called = true;
      return new Response("[]");
    }) as unknown as typeof globalThis.fetch;
    await applyResolverMetadata({
      endpoint: "http://hasura:8080/v1/metadata",
      role: "admin",
      adminSecret: "testing",
      metadata: buildResolverMetadata({}, {}, { sidecarUrl: "http://sc:9900" }),
      fetch,
    });
    expect(called).toBe(false);
  });

  it("names the failing Hasura call", async () => {
    const fetch = (async () =>
      new Response(JSON.stringify({ error: "type TopTrader is not defined", code: "validation-failed" }), {
        status: 400,
      })) as unknown as typeof globalThis.fetch;
    await expect(
      applyResolverMetadata({
        endpoint: "http://hasura:8080/v1/metadata",
        role: "admin",
        adminSecret: "testing",
        metadata: buildResolverMetadata({ topTraders: resolvers.topTraders }, types, { sidecarUrl: "http://sc:9900" }),
        fetch,
      }),
    ).rejects.toThrow(
      'Applying the resolvers to Hasura failed with 400: {"error":"type TopTrader is not defined","code":"validation-failed"}',
    );
  });
});

const contract = defineSidecar({
  functions: {},
  webhooks: { tipSent: { body: { from: S.string, amount: S.bigint } } },
});
const quiet = new Writable({ write: (_chunk, _enc, done) => done() });
const running: RunningSidecar[] = [];
afterEach(async () => {
  await Promise.all(running.splice(0).map((s) => s.close()));
});

const start = async (
  impl: Omit<SidecarImpl<typeof contract>, "functions">,
  options: { env?: NodeJS.ProcessEnv; resolvers?: readonly string[]; indexerInternalUrl?: string } = {},
) => {
  const sidecar = createSidecar(contract, { functions: {}, ...impl });
  const handle = await sidecar.start({
    internalPort: 0,
    publicPort: 0,
    env: options.env ?? {},
    ...(options.indexerInternalUrl === undefined ? {} : { indexerInternalUrl: options.indexerInternalUrl }),
    logDestination: quiet,
    ...(options.resolvers === undefined ? {} : { resolvers: options.resolvers }),
  });
  running.push(handle);
  return `http://127.0.0.1:${handle.publicPort}`;
};

const actionPayload = (name: string, input: unknown) => ({
  action: { name },
  input,
  session_variables: { "x-hasura-role": "public" },
  request_query: `query { ${name} { address } }`,
});

const call = async (base: string, name: string, input: unknown, headers: Record<string, string> = {}) => {
  const response = await fetch(`${base}/resolvers/${name}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(actionPayload(name, input)),
  });
  return { status: response.status, body: await response.json() };
};

describe("sidecar resolvers", () => {
  it("answers Hasura's action payload with the resolver's result, bigint as a string", async () => {
    const seen: unknown[] = [];
    const base = await start({
      resolvers: {
        topTraders: ({ args, request }) => {
          seen.push({ args, request });
          return [{ address: "0xa", volume: 12345678901234567890n, rank: 1 }];
        },
      },
    });

    expect({ reply: await call(base, "topTraders", { limit: 1 }), seen }).toEqual({
      reply: { status: 200, body: [{ address: "0xa", volume: "12345678901234567890", rank: 1 }] },
      seen: [
        {
          args: { limit: 1 },
          request: {
            role: "public",
            sessionVariables: { "x-hasura-role": "public" },
            query: "query { topTraders { address } }",
          },
        },
      ],
    });
  });

  it("maps errors to Hasura's action error shape", async () => {
    const base = await start({
      resolvers: {
        bad: () => {
          throw new ResolverError("limit too large", { code: "bad_input" });
        },
        broken: () => {
          throw new Error("database password is hunter2");
        },
      },
    });
    expect([await call(base, "bad", {}), await call(base, "broken", {}), await call(base, "missing", {})]).toEqual([
      { status: 400, body: { message: "limit too large", extensions: { code: "bad_input" } } },
      { status: 500, body: { message: "resolver 'broken' failed", extensions: { code: "internal" } } },
      { status: 404, body: { message: "no resolver 'missing' in this sidecar", extensions: { code: "not_found" } } },
    ]);
  });

  it("refuses calls without the shared secret once ENVIO_RESOLVER_SECRET is set", async () => {
    const base = await start(
      { resolvers: { topTraders: () => [] } },
      { env: { ENVIO_RESOLVER_SECRET: "s3cret" } },
    );
    expect([
      await call(base, "topTraders", {}),
      await call(base, "topTraders", {}, { [RESOLVER_SECRET_HEADER]: "wrong" }),
      await call(base, "topTraders", {}, { [RESOLVER_SECRET_HEADER]: "s3cret" }),
    ]).toEqual([
      { status: 401, body: { message: "unauthorized", extensions: { code: "unauthorized" } } },
      { status: 401, body: { message: "unauthorized", extensions: { code: "unauthorized" } } },
      { status: 200, body: [] },
    ]);
  });

  it("hands a resolver the contract's emit, which reaches the indexer's webhook listener", async () => {
    const received: Array<{ url: string | undefined; key: unknown; chain: unknown; body: unknown }> = [];
    const indexer = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        received.push({
          url: request.url,
          key: request.headers["idempotency-key"],
          chain: request.headers["x-envio-chain-id"],
          body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
        });
        response.writeHead(202, { "content-type": "application/json" });
        response.end(JSON.stringify({ id: "wh_1", chainId: 8453 }));
      });
    });
    await new Promise<void>((resolve) => indexer.listen(0, "127.0.0.1", resolve));
    const address = indexer.address();
    if (address === null || typeof address === "string") throw new Error("no port");
    try {
      const base = await start(
        {
          resolvers: {
            sendTip: async ({ args, emit }) => {
              const sent = await emit.tipSent(
                { from: String(args.from), amount: BigInt(String(args.amount)) },
                { chainId: 8453, idempotencyKey: "tip-1" },
              );
              return { accepted: true, webhookId: sent.id };
            },
          },
        },
        { indexerInternalUrl: `http://127.0.0.1:${address.port}` },
      );
      expect({ reply: await call(base, "sendTip", { from: "0xa", amount: "5" }), received }).toEqual({
        reply: { status: 200, body: { accepted: true, webhookId: "wh_1" } },
        received: [{ url: "/webhooks/tipSent", key: "tip-1", chain: "8453", body: { from: "0xa", amount: "5" } }],
      });
    } finally {
      indexer.closeAllConnections();
      await new Promise<void>((resolve) => indexer.close(() => resolve()));
    }
  });

  it("fails to start when config.yaml and createSidecar disagree on the resolvers", async () => {
    await expect(
      start({ resolvers: { topTraders: () => [], extra: () => [] } }, { resolvers: ["topTraders", "lonely"] }),
    ).rejects.toThrow(
      "Sidecar resolvers do not match config.yaml: 'lonely' is declared with handler: sidecar but not implemented in createSidecar({ resolvers }); 'extra' is implemented but not declared under resolvers: in config.yaml",
    );
  });
});
