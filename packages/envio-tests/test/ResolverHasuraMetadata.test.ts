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
            // the key is checked there, not at Hasura. Hasura's own ignore list
            // is left untouched -- naming anything would replace it wholesale.
            forward_client_headers: true,
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
      [{ name: "x-hasura-envio-resolver-secret", value: "s3cr3t" }],
      [{ name: "x-hasura-envio-resolver-secret", value: "s3cr3t" }],
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

  // A client header displaces an action's static header of the same name rather
  // than merging with it, so the secret that vouches for Hasura must sit under a
  // name a caller cannot speak for. Hasura takes every client `x-hasura-*`
  // header as a session variable and strips it before forwarding, which is why
  // this name holds: a caller's copy never reaches the handler as a header.
  //
  // Naming it so is what lets the metadata stay free of `ignored_client_headers`.
  // That field replaces Hasura's default list rather than extending it, so
  // setting it pins whatever the defaults were on the version we looked at --
  // and a later Hasura that defaults to ignoring one more header would forward
  // the client's copy of it instead, breaking every private resolver on an
  // upgrade nobody here was party to.
  it("puts the shared secret beyond a caller's reach without pinning Hasura's defaults", () => {
    const actions = buildHasuraMetadata(manifest, {
      handlerUrl: "http://resolvers:9900/hasura-action",
      actionSecret: "s3cr3t",
    }).actions;
    expect(
      actions.map((action: any) => ({
        name: action.name,
        headers: action.definition.headers,
        ignored: action.definition.ignored_client_headers,
      }))
    ).toEqual([
      {
        name: "accountPnl",
        headers: [{ name: "x-hasura-envio-resolver-secret", value: "s3cr3t" }],
        ignored: undefined,
      },
      {
        name: "referralCodeUpdates",
        headers: [{ name: "x-hasura-envio-resolver-secret", value: "s3cr3t" }],
        ignored: undefined,
      },
    ]);
  });

  it("refuses a manifest it cannot represent rather than emitting a partial one", () => {
    const bad = { ...manifest, types: [{ kind: "union", name: "Weird" }] };
    expect(() => buildHasuraMetadata(bad as never, { handlerUrl: "http://x" })).toThrow(
      /union/
    );
  });
});
