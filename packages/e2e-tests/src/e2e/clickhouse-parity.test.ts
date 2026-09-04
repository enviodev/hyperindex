/**
 * ClickHouse / Postgres parity.
 *
 * Runs the e2e_test indexer to its end block with both storages enabled, then
 * asserts the ClickHouse current-state views return exactly what the Postgres
 * entity tables hold. That is the only assertion that covers the whole write
 * path at once: the RowBinary encoder against real on-chain values, the
 * per-entity storage routing, the chain-id column under two different column
 * name formats, and the views' checkpoint dedup — which is what a reader
 * actually queries and which nothing else exercises.
 *
 * Needs Postgres and ClickHouse but no Docker: it drives `envio start` with
 * Hasura disabled rather than `envio dev`.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import path from "path";
import { config } from "../config.js";
import { runCommand } from "../utils/process.js";
import {
  queryClickHouse,
  isClickHouseReachable,
} from "../utils/clickhouse.js";
import { pgRows, closePg, isPgReachable } from "../utils/pg-direct.js";

const PROJECT_DIR = path.join(config.scenariosDir, "e2e_test");
const PG_SCHEMA = "e2e_ch_parity";
const CH_DATABASE = "e2e_ch_parity";
const END_BLOCK = "10861774";

const indexerEnv = {
  ENVIO_PG_SCHEMA: PG_SCHEMA,
  ENVIO_CLICKHOUSE_HOST: config.clickhouseUrl,
  ENVIO_CLICKHOUSE_USERNAME: config.clickhouseUsername,
  ENVIO_CLICKHOUSE_PASSWORD: config.clickhousePassword,
  ENVIO_CLICKHOUSE_DATABASE: CH_DATABASE,
  ENVIO_HASURA: "false",
  ENVIO_TUI: "false",
  // Off the default port, so a suite that reclaims 9898 cannot kill this run.
  ENVIO_INDEXER_PORT: "9899",
  ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
  E2E_EXPECTED_END_BLOCK: END_BLOCK,
};

const reachable = (await isPgReachable()) && (await isClickHouseReachable());

// In CI both services are provisioned, so an unreachable one is a broken
// pipeline rather than a machine without them.
if (!reachable && process.env.CI) {
  throw new Error(
    "Postgres or ClickHouse is unreachable, so the parity suite cannot run. Refusing to skip it in CI."
  );
}

/** Values as text, so a NUMERIC from Postgres and a String from ClickHouse compare. */
const asText = (rows: unknown[][]) =>
  rows.map((row) =>
    row.map((value) => (value === null ? null : String(value)))
  );

const chRows = async (query: string) => {
  const result = await queryClickHouse<{ data: Record<string, unknown>[] }>(query);
  return asText(result.data.map((row) => Object.values(row)));
};

describe.skipIf(!reachable)("E2E: ClickHouse mirrors Postgres", () => {
  beforeAll(async () => {
    const codegen = await runCommand(
      config.envioCommand,
      [...config.envioArgs, "codegen"],
      { cwd: PROJECT_DIR, env: indexerEnv, timeout: config.timeouts.codegen }
    );
    expect(codegen.exitCode, `codegen failed: ${codegen.stderr}`).toBe(0);

    // `-r` resets both backends, so the run starts from empty tables and the
    // comparison sees only what this run wrote. The indexer exits by itself once
    // every chain reaches its end block.
    const start = await runCommand(
      config.envioCommand,
      [...config.envioArgs, "start", "-r"],
      { cwd: PROJECT_DIR, env: indexerEnv, timeout: config.timeouts.test }
    );
    expect(start.exitCode, `indexer failed: ${start.stderr}`).toBe(0);
  }, config.timeouts.test + config.timeouts.codegen);

  afterAll(async () => {
    await closePg();
  });

  // Postgres renames columns to snake_case for this project while ClickHouse
  // keeps the schema's spelling, so each side is listed explicitly: the
  // assertion covers the naming as well as the values.
  //
  // Both sides order by id under `COLLATE "C"`, which is byte order — what
  // ClickHouse sorts a String by. Postgres would otherwise use the database's
  // own collation, where en_US largely ignores `-` at the primary level and ids
  // like `1-…` and `137-…` interleave differently than ClickHouse puts them,
  // failing the row-for-row comparison on data that actually matches.
  const expectParity = async (pgQuery: string, chQuery: string) => {
    const [pg, ch] = await Promise.all([pgRows(pgQuery), chRows(chQuery)]);
    expect({ hasRows: pg.length > 0, rows: ch }).toEqual({
      hasRows: true,
      rows: asText(pg),
    });
  };

  it("Transfer matches column for column", async () =>
    expectParity(
      `SELECT "id", "from", "to", "value", "block_number", "transaction_hash"
       FROM "${PG_SCHEMA}"."Transfer" ORDER BY "id" COLLATE "C"`,
      `SELECT id, \`from\`, \`to\`, value, blockNumber, transactionHash
       FROM ${CH_DATABASE}.\`Transfer\` ORDER BY id`
    ));

  // A per-chain entity carries the chain id in its primary key, spelled
  // `chain_id` in Postgres and `chainId` in ClickHouse.
  it("ChainTransfer matches, chain id included", async () =>
    expectParity(
      `SELECT "id", "from", "value", "chain_id"
       FROM "${PG_SCHEMA}"."ChainTransfer" ORDER BY "chain_id", "id" COLLATE "C"`,
      `SELECT id, \`from\`, value, chainId
       FROM ${CH_DATABASE}.\`ChainTransfer\` ORDER BY chainId, id`
    ));

  // The one entity written repeatedly under the same id, and deleted on some
  // events. Postgres holds one upserted row per id; ClickHouse holds every
  // change and its view has to resolve to the same answer — the highest
  // checkpoint per id, with deletes dropped.
  it("Holder matches after repeated writes and deletes", async () =>
    expectParity(
      `SELECT "id", "last_block", "last_value"
       FROM "${PG_SCHEMA}"."Holder" ORDER BY "id" COLLATE "C"`,
      `SELECT id, lastBlock, lastValue
       FROM ${CH_DATABASE}.\`Holder\` ORDER BY id`
    ));

  it("Holder deletes leave no row in either backend", async () => {
    // The handler sets this id and deletes it again within the same event, so a
    // DELETE row always reaches the history table and the final state is absent.
    const SENTINEL = "holder-deleted-sentinel";
    const [deletes, pgSurviving, chSurviving] = await Promise.all([
      chRows(
        `SELECT count() FROM ${CH_DATABASE}.\`envio_history_Holder\`
         WHERE envio_change = 'DELETE'`
      ),
      pgRows(`SELECT "id" FROM "${PG_SCHEMA}"."Holder" WHERE "id" = '${SENTINEL}'`),
      chRows(`SELECT id FROM ${CH_DATABASE}.\`Holder\` WHERE id = '${SENTINEL}'`),
    ]);
    expect({
      hasDeleteRows: Number(deletes.at(0)?.at(0) ?? 0) > 0,
      pgSurviving,
      chSurviving,
    }).toEqual({ hasDeleteRows: true, pgSurviving: [], chSurviving: [] });
  });

  it("routes each entity to only the storages it declares", async () => {
    const [chTables, pgTables] = await Promise.all([
      queryClickHouse<{ data: { name: string }[] }>(
        `SELECT name FROM system.tables WHERE database = '${CH_DATABASE}' AND engine = 'View' ORDER BY name`
      ).then((r) => r.data.map((t) => t.name)),
      pgRows(
        `SELECT table_name FROM information_schema.tables
         WHERE table_schema = '${PG_SCHEMA}' AND table_type = 'BASE TABLE'
           AND table_name NOT LIKE 'envio%' AND table_name <> 'raw_events'
         ORDER BY table_name`
      ).then((rows) => rows.map(([name]) => String(name))),
    ]);
    expect({ clickhouse: chTables, postgres: pgTables }).toEqual({
      clickhouse: ["ChainTransfer", "Holder", "Transfer", "TransferChOnly"],
      postgres: [
        "Account",
        "ChainAccount",
        "ChainAccount$1",
        "ChainTransfer",
        "ChainTransfer$1",
        "Holder",
        "NumericArrays",
        "Transfer",
        "TransferInternal",
        "TransferPgOnly",
      ],
    });
  });

  // The view reads rows up to `max(id)` in the checkpoints table, so a history
  // row above it is invisible — the failure mode of a batch whose rows landed
  // but whose checkpoints did not. Postgres is not compared here: it writes no
  // checkpoints during a backfill, while ClickHouse always needs them.
  it("leaves no ClickHouse history row above the last checkpoint", async () => {
    const above = await chRows(
      `SELECT sum(rows_above) FROM (
         SELECT count() AS rows_above FROM ${CH_DATABASE}.\`envio_history_Transfer\`
         WHERE envio_checkpoint_id > (SELECT max(id) FROM ${CH_DATABASE}.envio_checkpoints)
         UNION ALL
         SELECT count() AS rows_above FROM ${CH_DATABASE}.\`envio_history_Holder\`
         WHERE envio_checkpoint_id > (SELECT max(id) FROM ${CH_DATABASE}.envio_checkpoints)
         UNION ALL
         SELECT count() AS rows_above FROM ${CH_DATABASE}.\`envio_history_ChainTransfer\`
         WHERE envio_checkpoint_id > (SELECT max(id) FROM ${CH_DATABASE}.envio_checkpoints)
       )`
    );
    expect(above).toEqual([["0"]]);
  });
});
