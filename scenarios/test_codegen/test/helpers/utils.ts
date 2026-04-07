import { spawn } from "child_process";
import { makeClient } from "envio/src/PgStorage.gen";

export const createSql = makeClient;

// Call the envio binary directly instead of going through `pnpm exec` to
// avoid pnpm's startup overhead in tight test loops.
const ENVIO_BIN = "./node_modules/.bin/envio";

// `setup` drops the schema and re-creates it (equivalent to the previous
// runUpMigrations(reset=true) call). Tests rely on a clean schema before
// every run.
const spawnDbMigrateSetup = (silent: boolean) =>
  new Promise<void>((resolve, reject) => {
    const child = spawn(ENVIO_BIN, ["local", "db-migrate", "setup"], {
      stdio: silent ? "ignore" : "inherit",
      cwd: process.cwd(),
    });
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`db-migrate setup exited with code ${code}`));
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
