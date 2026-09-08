import { describe, expect, it } from "vitest";
import {
  buildRegisteredManifest,
  createResolver,
  defineEnum,
  defineInput,
  defineType,
  S,
} from "envio";
import { buildHasuraMetadata } from "envio/src/resolvers/hasuraMetadata.js";

// The manifest `envio codegen` writes, turned into the metadata Hasura needs to
// expose each resolver as an action. Pure: manifest in, JSON out, no I/O.
//
// The manifest here is built from real declarations rather than written by
// hand. A hand-written one can disagree with what codegen actually emits, and
// then the metadata is only correct against a manifest that never exists.

const Period = defineEnum("Period", ["Day", "Week"]);
const Bucket = defineType("Bucket", {
  label: S.string,
  pnl: S.bigint,
  note: S.optional(S.string),
});

const Where = defineInput("AccountPnlWhereInput", {
  account: S.string,
  minCapital: S.optional(S.bigint),
});

createResolver({
  name: "accountPnl",
  description: "PnL per bucket",
  args: { where: Where, period: S.optional(Period) },
  output: S.array(Bucket),
  timeoutMs: 30_000,
  handler: async () => [],
});

createResolver({
  name: "referralCodeUpdates",
  output: S.optional(S.string),
  admin: true,
  timeoutMs: 5_000,
  handler: async () => undefined,
});

const { manifest } = buildRegisteredManifest();

describe("manifest -> Hasura metadata", () => {
  it("becomes custom types, actions and permissions", () => {
    expect(
      buildHasuraMetadata(manifest, { handlerUrl: "http://resolvers:9900/hasura-action" })
    ).toEqual({
      customTypes: {
        scalars: [{ name: "BigInt" }],
        enums: [{ name: "Period", values: [{ value: "Day" }, { value: "Week" }] }],
        input_objects: [
          {
            name: "AccountPnlWhereInput",
            fields: [
              { name: "account", type: "String!" },
              { name: "minCapital", type: "BigInt" },
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
      },
      actions: [
        {
          name: "accountPnl",
          comment: "PnL per bucket",
          definition: {
            // A Hasura action is a mutation unless it says otherwise, and the
            // manifest's SDL says `extend type Query`.
            type: "query",
            kind: "synchronous",
            handler: "http://resolvers:9900/hasura-action",
            arguments: [
              { name: "where", type: "AccountPnlWhereInput!" },
              { name: "period", type: "Period" },
            ],
            output_type: "[Bucket!]!",
            timeout: 31,
          },
        },
        {
          name: "referralCodeUpdates",
          definition: {
            type: "query",
            kind: "synchronous",
            handler: "http://resolvers:9900/hasura-action",
            arguments: [],
            output_type: "String",
            timeout: 6,
            // Private, so the caller's own headers have to reach the service:
            // the key is checked there, not at Hasura. All but the shared
            // secret's, which a forwarded header would otherwise displace.
            forward_client_headers: true,
            ignored_client_headers: [
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
              "x-envio-resolver-secret",
            ],
          },
        },
      ],
      // Every action is granted to `public`, private ones included: without the
      // permission Hasura will not route the call, and then the key check at
      // the service has nothing to run against.
      permissions: [
        { action: "accountPnl", role: "public" },
        { action: "referralCodeUpdates", role: "public" },
      ],
    });
  });

  // Without this the service can only take the caller's word for its own role,
  // so anything that can reach the pod can claim `admin`. Hasura sends the
  // header because the action declares it, and the value is literal so no
  // Hasura-side configuration is involved.
  it("declares a shared-secret header on every action when one is configured", () => {
    const withSecret = buildHasuraMetadata(manifest, {
      handlerUrl: "http://resolvers:9900/hasura-action",
      actionSecret: "s3cr3t",
    });
    expect(withSecret.actions.map((a: any) => a.definition.headers)).toEqual([
      [{ name: "x-envio-resolver-secret", value: "s3cr3t" }],
      [{ name: "x-envio-resolver-secret", value: "s3cr3t" }],
    ]);
  });

  // Hasura's `timeout` bounds the whole HTTP call; the resolver's `timeoutMs`
  // bounds only the queries inside it. Acquiring a connection, parsing
  // arguments and serializing the result all spend Hasura's budget without
  // spending the resolver's, so equal deadlines let Hasura abort a request the
  // resolver still considers live -- and Hasura aborting reaches the client as
  // an unreachable webhook rather than as the resolver's own timeout.
  it("gives Hasura's timeout headroom over the resolver's query timeout", () => {
    const actions = buildHasuraMetadata(manifest, {
      handlerUrl: "http://resolvers:9900/hasura-action",
    }).actions;
    expect(
      manifest.resolvers.map((resolver: any) => [
        resolver.timeoutMs,
        actions.find((action: any) => action.name === resolver.name)!.definition.timeout,
      ])
    ).toEqual([
      [30_000, 31],
      [5_000, 6],
    ]);
  });

  // Verified against Hasura v2.43.0: with `forward_client_headers` on, a client
  // header of the same name does not merge with the action's static header --
  // it replaces it, and the static value is never sent. So any caller could
  // send `x-envio-resolver-secret` and make the service reject the request as
  // unauthenticated, denying the six private resolvers to their key holders.
  // Ignoring the name is what makes the static value win. The rest of the list
  // is Hasura's own default, restated because supplying the field replaces that
  // default wholesale rather than adding to it -- dropping `Content-Length`
  // alone forwards the client's, and every request fails to parse.
  it("keeps a client from displacing the shared secret on a private action", () => {
    const actions = buildHasuraMetadata(manifest, {
      handlerUrl: "http://resolvers:9900/hasura-action",
      actionSecret: "s3cr3t",
    }).actions;
    expect(
      actions.map((action: any) => [
        action.name,
        action.definition.ignored_client_headers,
      ])
    ).toEqual([
      ["accountPnl", undefined],
      [
        "referralCodeUpdates",
        [
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
          "x-envio-resolver-secret",
        ],
      ],
    ]);
  });

  it("refuses a manifest it cannot represent rather than emitting a partial one", () => {
    const bad = { ...manifest, types: [{ kind: "union", name: "Weird" }] };
    expect(() => buildHasuraMetadata(bad as never, { handlerUrl: "http://x" })).toThrow(
      /union/
    );
  });
});
