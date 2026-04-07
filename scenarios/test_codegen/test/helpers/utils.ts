import { spawn } from "child_process";
// Import from the compiled .res.mjs directly. The .gen.ts re-export
// can't be used here because Node 24 refuses to strip TypeScript types
// from files inside node_modules.
import { makeClient } from "envio/src/PgStorage.res.mjs";

export const createSql = makeClient as () => any;

// Call the envio binary directly (via node_modules/.bin) instead of
// going through `pnpm exec` to avoid pnpm's startup overhead in tight
// test loops. `db-migrate setup` drops the schema and re-creates it,
// matching the previous runUpMigrations(reset=true) behavior.
const ENVIO_BIN = "./node_modules/.bin/envio";

const spawnDbMigrateSetup = (silent: boolean) =>
  new Promise<void>((resolve, reject) => {
    const child = spawn(ENVIO_BIN, ["local", "db-migrate", "setup"], {
      stdio: silent ? "ignore" : "inherit",
      cwd: process.cwd(),
    });
    child.on("exit", (code, signal) => {
      if (code === 0) {
        resolve();
      } else {
        const reason = signal ? `signal ${signal}` : `code ${code}`;
        reject(new Error(`db-migrate setup exited with ${reason}`));
      }
    });
    child.on("error", reject);
  });

export const runMigrationsNoExit = () => spawnDbMigrateSetup(false);
export const runMigrationsNoLogs = () => spawnDbMigrateSetup(true);

export enum EventVariants {
  NftFactoryContract_SimpleNftCreatedEvent,
  SimpleNftContract_TransferEvent,
}
