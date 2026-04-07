import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import path from "path";

// Import from the compiled .res.mjs directly. The .gen.ts re-export
// can't be used here because Node 24 refuses to strip TypeScript types
// from files inside node_modules.
import { makeClient } from "envio/src/PgStorage.res.mjs";
// @ts-expect-error — no .d.ts for the ReScript-compiled migrations module
import { runUpMigrations } from "envio/src/Migrations.res.mjs";

export const createSql = makeClient as () => any;

// Migrations.res reads the config from process.env.ENVIO_CONFIG via
// Config.fromEnv(). Load it once from the generated internal.config.json
// so per-file beforeAll/afterAll hooks can call runUpMigrations directly
// without spawning a subprocess.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
process.env.ENVIO_CONFIG = readFileSync(
  path.join(__dirname, "../../generated/internal.config.json"),
  "utf-8"
);

const originalConsoleLog = console.log;

export const disableConsoleLog = () => {
  console.log = () => undefined;
};

export const enableConsoleLog = () => {
  console.log = originalConsoleLog;
};

export const runMigrationsNoExit = async () => {
  // shouldExit=false, reset=true — matches the pre-refactor behaviour of
  // the generated test helpers that fully re-created the DB schema
  // between test files.
  await (runUpMigrations as any)(false, true);
};

export const runFunctionNoLogs = async (func: () => any) => {
  disableConsoleLog();
  await func();
  enableConsoleLog();
};

export const runMigrationsNoLogs = () => runFunctionNoLogs(runMigrationsNoExit);

export enum EventVariants {
  NftFactoryContract_SimpleNftCreatedEvent,
  SimpleNftContract_TransferEvent,
}
