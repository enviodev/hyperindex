import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server, type ServerResponse } from "node:http";
import {
  buildRegisteredManifest,
  createResolver,
  defineEnum,
  defineInput,
  defineType,
  S,
} from "envio";
import { buildHasuraMetadata } from "envio/src/resolvers/hasuraMetadata.js";
import {
  applyResolverMetadata,
  startMetadataReassert,
} from "envio/src/resolvers/hasuraApply.js";

// Applying the metadata, against a stand-in that answers Hasura's metadata API.
//
// The "already applied" state below is not written by hand -- it is the exact
// body `export_metadata` returned from hasura/graphql-engine:v2.43.0 after this
// same manifest was applied to it. Hasura normalises what it stores (it drops
// `kind` when synchronous, `arguments` when empty and `timeout` when it is the
// default 30, adds `ignored_client_headers`, gives enum values a null
// `description` and `is_deprecated`, and nests permissions under the action),
// so a fixture invented from our own output would agree with us and with
// nothing else.

const HANDLER = "http://host.docker.internal:9911/hasura-action";

const Period = defineEnum("Period", ["Day", "Week"]);
const Where = defineInput("MarketAprsWhereInput", {
  periodStart: S.int32,
  marketAddresses: S.optional(S.array(S.string)),
});
const Bucket = defineType("Bucket", {
  label: S.string,
  pnl: S.bigint,
  note: S.optional(S.string),
});

createResolver({
  name: "marketsAprByPeriod",
  description: "APR by market",
  args: { where: Where, period: S.optional(Period) },
  output: S.array(Bucket),
  timeoutMs: 30_000,
  handler: async () => [],
});

createResolver({
  name: "secretStats",
  output: S.optional(S.string),
  admin: true,
  timeoutMs: 5_000,
  handler: async () => undefined,
});

const metadata = buildHasuraMetadata(buildRegisteredManifest().manifest, {
  handlerUrl: HANDLER,
});

const IGNORED_CLIENT_HEADERS = [
  "Content-Length",
  "Content-MD5",
  "User-Agent",
  "Host",
  "Origin",
  "Referer",
  "Accept",
  "Accept-Encoding",
  "Accept-Language",
  "Accept-Datetime",
  "Cache-Control",
  "Connection",
  "DNT",
  "Content-Type",
];

const APPLIED_EXPORT = {
  version: 3,
  sources: [],
  actions: [
    {
      name: "marketsAprByPeriod",
      definition: {
        handler: HANDLER,
        output_type: "[Bucket!]!",
        ignored_client_headers: IGNORED_CLIENT_HEADERS,
        arguments: [
          { name: "where", type: "MarketAprsWhereInput!" },
          { name: "period", type: "Period" },
        ],
        type: "query",
        timeout: 31,
      },
      comment: "APR by market",
      permissions: [{ role: "public" }],
    },
    {
      name: "secretStats",
      definition: {
        handler: HANDLER,
        output_type: "String",
        ignored_client_headers: IGNORED_CLIENT_HEADERS,
        type: "query",
        timeout: 6,
        forward_client_headers: true,
      },
      permissions: [{ role: "public" }],
    },
  ],
  custom_types: {
    input_objects: [
      {
        name: "MarketAprsWhereInput",
        fields: [
          { name: "periodStart", type: "Int!" },
          { name: "marketAddresses", type: "[String!]" },
        ],
      },
    ],
    objects: [
      {
        name: "Bucket",
        fields: [
          { name: "label", type: "String!" },
          { name: "pnl", type: "BigInt!" },
          { name: "note", type: "String" },
        ],
      },
    ],
    scalars: [{ name: "BigInt" }],
    enums: [
      {
        name: "Period",
        values: [
          { description: null, is_deprecated: null, value: "Day" },
          { description: null, is_deprecated: null, value: "Week" },
        ],
      },
    ],
  },
};

const EMPTY_EXPORT = { version: 3, sources: [] };

type Request = { type: string; args: unknown };

let server: Server;
let endpoint: string;
let exported: unknown = EMPTY_EXPORT;
let received: Request[] = [];
let secrets: (string | undefined)[] = [];

beforeAll(async () => {
  server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      received.push(body);
      secrets.push(request.headers["x-hasura-admin-secret"] as string | undefined);
      const answer =
        body.type === "export_metadata"
          ? exported
          : body.args.map(() => ({ message: "success" }));
      const payload = JSON.stringify(answer);
      response.writeHead(200, {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(payload),
      });
      response.end(payload);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address();
  endpoint = `http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}/v1/metadata`;
});

afterEach(() => {
  received = [];
  secrets = [];
  exported = EMPTY_EXPORT;
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const apply = () =>
  applyResolverMetadata({ endpoint, adminSecret: "testing", metadata });

const bulkSent = () => received.filter((r) => r.type === "bulk");

describe("applying resolver metadata", () => {
  it("creates everything on a Hasura that has none of it", async () => {
    const result = await apply();
    expect({
      applied: result.applied,
      secrets,
      bulk: bulkSent(),
    }).toEqual({
      applied: true,
      secrets: ["testing", "testing"],
      bulk: [
        {
          type: "bulk",
          args: [
            { type: "set_custom_types", args: metadata.customTypes },
            {
              type: "create_action",
              args: {
                name: "marketsAprByPeriod",
                comment: "APR by market",
                definition: metadata.actions[0].definition,
              },
            },
            {
              type: "create_action",
              args: {
                name: "secretStats",
                definition: metadata.actions[1].definition,
              },
            },
            {
              type: "create_action_permission",
              args: { action: "marketsAprByPeriod", role: "public" },
            },
            // The private one is granted to `public` too: Hasura has to route
            // the call before the service can check the caller's key.
            {
              type: "create_action_permission",
              args: { action: "secretStats", role: "public" },
            },
          ],
        },
      ],
    });
  });

  it("writes nothing when Hasura already holds it", async () => {
    // The metadata write reloads Hasura's schema cache, so re-asserting every
    // minute has to be a read that finds nothing to do.
    exported = APPLIED_EXPORT;
    const result = await apply();
    expect({ applied: result.applied, reasons: result.reasons, bulk: bulkSent() }).toEqual({
      applied: false,
      reasons: [],
      bulk: [],
    });
  });

  it("updates an action whose definition has moved, and leaves the rest alone", async () => {
    exported = {
      ...APPLIED_EXPORT,
      actions: [
        {
          ...APPLIED_EXPORT.actions[0],
          definition: { ...APPLIED_EXPORT.actions[0].definition, handler: "http://old:9900/resolve" },
        },
        APPLIED_EXPORT.actions[1],
      ],
    };
    const result = await apply();
    expect({
      reasons: result.reasons,
      args: bulkSent()[0]!.args,
    }).toEqual({
      reasons: ["action 'marketsAprByPeriod' differs"],
      args: [
        {
          type: "update_action",
          args: {
            name: "marketsAprByPeriod",
            comment: "APR by market",
            definition: metadata.actions[0].definition,
          },
        },
      ],
    });
  });

  it("drops an action the manifest no longer declares", async () => {
    exported = {
      ...APPLIED_EXPORT,
      actions: [
        ...APPLIED_EXPORT.actions,
        { name: "renamedAway", definition: { handler: HANDLER, output_type: "String", type: "query" } },
      ],
    };
    const result = await apply();
    expect({ reasons: result.reasons, args: bulkSent()[0]!.args }).toEqual({
      reasons: ["action 'renamedAway' is no longer declared"],
      args: [{ type: "drop_action", args: { name: "renamedAway" } }],
    });
  });

  it("revokes a role a resolver no longer grants", async () => {
    // Every action this service declares is readable by `public`, private ones
    // included, so a revoke is now about a role that is not ours at all --
    // something granted by hand, or left behind by an older manifest.
    exported = {
      ...APPLIED_EXPORT,
      actions: [
        APPLIED_EXPORT.actions[0],
        {
          ...APPLIED_EXPORT.actions[1],
          permissions: [{ role: "public" }, { role: "leftover" }],
        },
      ],
    };
    const result = await apply();
    // `drop_action_permission` names the action `name`, where
    // `create_action_permission` names it `action`.
    expect({ reasons: result.reasons, args: bulkSent()[0]!.args }).toEqual({
      reasons: ["action 'secretStats' should not be readable by 'leftover'"],
      args: [
        { type: "drop_action_permission", args: { name: "secretStats", role: "leftover" } },
      ],
    });
  });

  it("keeps a type that is going away until nothing references it", async () => {
    // `set_custom_types` is validated the moment it runs, so dropping a type an
    // action still names fails the whole bulk. The current set is asserted
    // first, the actions move off it, and only then is the desired set written.
    exported = {
      ...APPLIED_EXPORT,
      custom_types: {
        ...APPLIED_EXPORT.custom_types,
        objects: [
          ...APPLIED_EXPORT.custom_types.objects,
          { name: "Stale", fields: [{ name: "gone", type: "String!" }] },
        ],
      },
    };
    const result = await apply();
    const args = bulkSent()[0]!.args as { type: string; args: unknown }[];
    expect({
      reasons: result.reasons,
      shape: args.map((a) => a.type),
      first: args[0]!.args,
      last: args[args.length - 1]!.args,
    }).toEqual({
      reasons: ["custom types differ"],
      shape: ["set_custom_types", "set_custom_types"],
      first: {
        ...metadata.customTypes,
        objects: [...metadata.customTypes.objects, { name: "Stale", fields: [{ name: "gone", type: "String!" }] }],
      },
      last: metadata.customTypes,
    });
  });

  // A Hasura that sends headers and then stops writing leaves `response.json()`
  // pending forever. Unbounded, that leaves `applyResolverMetadata` pending
  // too, and the re-assert loop's own guard against overlapping applies then
  // skips every later tick: the service stops healing and never says why.
  it("gives up on a Hasura that answers with headers and then stalls", async () => {
    const stalled: ServerResponse[] = [];
    const stalling = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "application/json" });
      // Headers only. No body, no end.
      response.write("");
      stalled.push(response);
    });
    await new Promise<void>((resolve) => stalling.listen(0, "127.0.0.1", () => resolve()));
    const address = stalling.address();
    const stallingEndpoint = `http://127.0.0.1:${
      typeof address === "object" && address ? address.port : 0
    }/v1/metadata`;

    const errors: string[] = [];
    const stop = startMetadataReassert({
      endpoint: stallingEndpoint,
      adminSecret: "testing",
      metadata,
      intervalMs: 20,
      timeoutMs: 60,
      onApplied: () => {},
      onError: (error: Error) => errors.push(error.name),
    });
    try {
      const deadline = Date.now() + 5_000;
      while (errors.length < 2 && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    } finally {
      stop();
      for (const response of stalled) response.destroy();
      await new Promise<void>((resolve) => stalling.close(() => resolve()));
    }

    // Twice, not once: the first give-up has to release the loop's guard so a
    // later tick tries again.
    expect(errors.length >= 2).toBe(true);
  });

  // An apply is two calls, so a per-call deadline is not a bound on the apply.
  // A Hasura that stalls the export and then the bulk holds `running` for
  // twice the deadline, and the re-assert loop skips every tick in between --
  // the guard meant to stop applies overlapping instead stops them happening.
  it("bounds the whole apply, not each call within it", async () => {
    let served = 0;
    const stalled: ServerResponse[] = [];
    // The export answers immediately so the apply reaches its second call;
    // that one stalls. Both must fit inside the one deadline.
    const halfStalling = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk) => chunks.push(chunk));
      request.on("end", () => {
        served += 1;
        if (served === 1) {
          // Slow, but inside its own deadline and successful, so the apply
          // goes on to its second call with most of the budget already spent.
          const payload = JSON.stringify(EMPTY_EXPORT);
          setTimeout(() => {
            response.writeHead(200, {
              "content-type": "application/json",
              "content-length": Buffer.byteLength(payload),
            });
            response.end(payload);
          }, 250);
          return;
        }
        response.writeHead(200, { "content-type": "application/json" });
        stalled.push(response);
      });
    });
    await new Promise<void>((resolve) => halfStalling.listen(0, "127.0.0.1", () => resolve()));
    const address = halfStalling.address();
    const halfEndpoint = `http://127.0.0.1:${
      typeof address === "object" && address ? address.port : 0
    }/v1/metadata`;

    const started = Date.now();
    await applyResolverMetadata({
      endpoint: halfEndpoint,
      adminSecret: "testing",
      metadata,
      timeoutMs: 300,
    }).catch(() => "failed");
    const elapsed = Date.now() - started;

    for (const response of stalled) response.destroy();
    await new Promise<void>((resolve) => halfStalling.close(() => resolve()));

    // A 250ms export then a stalled bulk is 550ms if each call gets its own
    // 300ms; it is ~300ms if the deadline belongs to the apply.
    expect([served, elapsed < 450]).toEqual([2, true]);
  });

  // The dangerous shape of the same failure: a 2xx nobody can parse used to
  // become `null`, which reads exactly like a Hasura holding no actions at all
  // -- so the very next step would recreate every action over a Hasura that
  // already had them.
  it("treats a 2xx it cannot parse as a failure, not as an empty Hasura", async () => {
    const garbage = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end("<html>gateway</html>");
    });
    await new Promise<void>((resolve) => garbage.listen(0, "127.0.0.1", () => resolve()));
    const address = garbage.address();
    const garbageEndpoint = `http://127.0.0.1:${
      typeof address === "object" && address ? address.port : 0
    }/v1/metadata`;

    const outcome = await applyResolverMetadata({
      endpoint: garbageEndpoint,
      adminSecret: "testing",
      metadata,
    }).then(
      () => "applied",
      (error: Error) => error.message
    );
    await new Promise<void>((resolve) => garbage.close(() => resolve()));

    expect(outcome).toMatch(/could not be read/);
  });

  it("leaves a newer deployment's metadata alone rather than reverting it", async () => {
    // A rolling update runs both versions at once. The new pod updates the
    // actions to its own definitions; if the old pod's re-assert treated that
    // as drift it would write the old ones straight back, and the two would
    // fight over the published schema until the rollout finished. Clients would
    // see a field's type flap. So the loop heals what is *missing* and never
    // argues about what differs -- reconciling definitions is startup's job.
    exported = {
      ...APPLIED_EXPORT,
      actions: APPLIED_EXPORT.actions.map((action) => ({
        ...action,
        definition: { ...action.definition, handler: "http://the-new-pod:9900/hasura-action" },
      })),
    };
    const stop = startMetadataReassert({
      endpoint,
      adminSecret: "testing",
      metadata,
      intervalMs: 20,
      onApplied: () => {},
      onError: () => {},
    });
    try {
      await new Promise((resolve) => setTimeout(resolve, 90));
    } finally {
      stop();
    }
    expect(bulkSent()).toEqual([]);
  });

  it("leaves a rename alone: some of ours present is not the wipe it heals", async () => {
    // A newer deployment that renames a resolver leaves the old name absent and
    // the rest present. Treating any absence as the wipe would have the older
    // pod restore its whole set over the newer one for the length of a rollout.
    // Only a Hasura holding none of them is the `clear_metadata` this heals.
    exported = {
      ...APPLIED_EXPORT,
      actions: [APPLIED_EXPORT.actions[0]],
    };
    const stop = startMetadataReassert({
      endpoint,
      adminSecret: "testing",
      metadata,
      intervalMs: 20,
      onApplied: () => {},
      onError: () => {},
    });
    try {
      await new Promise((resolve) => setTimeout(resolve, 90));
    } finally {
      stop();
    }
    expect(bulkSent()).toEqual([]);
  });

  it("re-applies after a clear_metadata wipes it, without being asked", async () => {
    // `Hasura.trackDatabase` opens with a wholesale `clear_metadata`, so a
    // re-initialised indexer silently deletes the actions while this service
    // keeps running and answering nothing.
    exported = APPLIED_EXPORT;
    const applies: string[][] = [];
    const stop = startMetadataReassert({
      endpoint,
      adminSecret: "testing",
      metadata,
      intervalMs: 20,
      onApplied: (reasons: string[]) => applies.push(reasons),
      onError: () => {},
    });
    try {
      await new Promise((resolve) => setTimeout(resolve, 60));
      expect(applies).toEqual([]);
      exported = EMPTY_EXPORT;
      await new Promise((resolve) => setTimeout(resolve, 120));
    } finally {
      stop();
    }
    expect([applies.length > 0, bulkSent().length > 0]).toEqual([true, true]);
  });
});
