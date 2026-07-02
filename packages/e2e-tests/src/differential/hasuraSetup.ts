/**
 * Replicates the exact Hasura metadata configuration that
 * packages/envio/src/Hasura.res `trackDatabase` applies at indexer init,
 * with the response limit and aggregate-entity set as knobs so test phases
 * can vary them without re-running the indexer.
 */

import { readFile } from "node:fs/promises";
import { adminSecret, hasuraUrl, pgSchema } from "./env.js";
import { entityTables, allTrackedTables } from "./fixtureModel.js";

async function metadataOp(operation: unknown): Promise<unknown> {
  const res = await fetch(`${hasuraUrl}/v1/metadata`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Hasura-Role": "admin",
      "X-Hasura-Admin-Secret": adminSecret,
    },
    body: JSON.stringify(operation),
  });
  const body = (await res.json()) as { code?: string };
  if (!res.ok) {
    const code = body?.code;
    if (code === "already-exists" || code === "already-tracked") return body;
    throw new Error(
      `Hasura metadata op failed (${res.status}): ${JSON.stringify(body)}`
    );
  }
  return body;
}

export async function runSql(sql: string): Promise<string[][]> {
  const res = await fetch(`${hasuraUrl}/v2/query`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-hasura-admin-secret": adminSecret,
    },
    body: JSON.stringify({ type: "run_sql", args: { sql } }),
  });
  if (!res.ok) {
    throw new Error(`run_sql failed (${res.status}): ${await res.text()}`);
  }
  const body = (await res.json()) as { result?: string[][] };
  return body.result?.slice(1) ?? [];
}

export async function applyFixture(fixtureDir: URL): Promise<void> {
  const schemaSql = await readFile(new URL("schema.sql", fixtureDir), "utf8");
  const seedSql = await readFile(new URL("seed.sql", fixtureDir), "utf8");
  await runSql(schemaSql);
  await runSql(seedSql);
}

export interface TrackOptions {
  responseLimit?: number;
  aggregateEntities?: string[];
}

export async function trackDatabase(options: TrackOptions = {}): Promise<void> {
  const { responseLimit, aggregateEntities = [] } = options;

  await metadataOp({ type: "clear_metadata", args: {} });
  await metadataOp({
    type: "reload_metadata",
    args: { reload_sources: ["default"] },
  });

  await metadataOp({
    type: "pg_track_tables",
    args: {
      allow_warnings: false,
      tables: allTrackedTables.map((tableName) => ({
        table: { name: tableName, schema: pgSchema },
        configuration: { custom_name: tableName },
      })),
    },
  });

  for (const tableName of allTrackedTables) {
    const permission: Record<string, unknown> = {
      columns: "*",
      filter: {},
      allow_aggregations: aggregateEntities.includes(tableName),
    };
    if (responseLimit !== undefined) permission.limit = responseLimit;
    await metadataOp({
      type: "pg_create_select_permission",
      args: {
        table: { schema: pgSchema, name: tableName },
        role: "public",
        source: "default",
        permission,
      },
    });
  }

  for (const entity of entityTables) {
    for (const rel of entity.arrayRelationships ?? []) {
      await metadataOp({
        type: "pg_create_array_relationship",
        args: {
          table: { schema: pgSchema, name: entity.name },
          name: rel.name,
          source: "default",
          using: {
            manual_configuration: {
              remote_table: { schema: pgSchema, name: rel.remoteTable },
              column_mapping: { id: rel.remoteColumn },
            },
          },
        },
      });
    }
    for (const rel of entity.objectRelationships ?? []) {
      await metadataOp({
        type: "pg_create_object_relationship",
        args: {
          table: { schema: pgSchema, name: entity.name },
          name: rel.name,
          source: "default",
          using: {
            manual_configuration: {
              remote_table: { schema: pgSchema, name: rel.remoteTable },
              column_mapping: { [rel.column]: "id" },
            },
          },
        },
      });
    }
  }
}
