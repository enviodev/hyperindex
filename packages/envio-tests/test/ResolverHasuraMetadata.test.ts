import { describe, expect, it } from "vitest";
import { buildHasuraMetadata } from "../../envio/src/resolvers/hasuraMetadata.js";

// The manifest `envio codegen` writes, turned into the metadata Hasura needs to
// expose each resolver as an action. Pure: manifest in, JSON out, no I/O.
const manifest = {
  schemaVersion: 1,
  resolvers: [
    {
      name: "accountPnl",
      description: "PnL per bucket",
      args: [
        { name: "account", type: "String!" },
        { name: "period", type: "Period" },
      ],
      type: "[Bucket!]!",
      admin: false,
      cacheTtlMs: 60_000,
      timeoutMs: 30_000,
    },
    {
      name: "referralCodeUpdates",
      args: [],
      type: "String",
      admin: true,
      cacheTtlMs: 0,
      timeoutMs: 5_000,
    },
  ],
  types: [
    {
      kind: "object",
      name: "Bucket",
      fields: [
        { name: "label", type: "String!" },
        { name: "pnl", type: "BigInt!" },
        { name: "note", type: "String" },
      ],
    },
    { kind: "enum", name: "Period", values: ["Day", "Week"] },
    { kind: "scalar", name: "BigInt" },
  ],
};

describe("manifest -> Hasura metadata", () => {
  it("becomes custom types, actions and permissions", () => {
    expect(
      buildHasuraMetadata(manifest, { handlerUrl: "http://resolvers:9900/hasura-action" })
    ).toEqual({
      customTypes: {
        scalars: [{ name: "BigInt" }],
        enums: [{ name: "Period", values: [{ value: "Day" }, { value: "Week" }] }],
        input_objects: [],
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
            kind: "synchronous",
            handler: "http://resolvers:9900/hasura-action",
            arguments: [
              { name: "account", type: "String!" },
              { name: "period", type: "Period" },
            ],
            output_type: "[Bucket!]!",
            timeout: 30,
          },
        },
        {
          name: "referralCodeUpdates",
          definition: {
            kind: "synchronous",
            handler: "http://resolvers:9900/hasura-action",
            arguments: [],
            output_type: "String",
            timeout: 5,
          },
        },
      ],
      // Admin always has access in Hasura, so an admin-only resolver is simply
      // one with no public permission — nothing to grant, nothing to revoke.
      permissions: [{ action: "accountPnl", role: "public" }],
    });
  });

  it("refuses a manifest it cannot represent rather than emitting a partial one", () => {
    const bad = { ...manifest, types: [{ kind: "union", name: "Weird" }] };
    expect(() => buildHasuraMetadata(bad as never, { handlerUrl: "http://x" })).toThrow(
      /union/
    );
  });
});
