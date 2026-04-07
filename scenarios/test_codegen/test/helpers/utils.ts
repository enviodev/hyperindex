import { spawn } from "child_process";
import { makeClient } from "envio/src/PgStorage.res.mjs";

export const createSql = makeClient;

const spawnDbMigrateUp = (silent: boolean) =>
  new Promise<void>((resolve, reject) => {
    const child = spawn(
      "pnpm",
      ["exec", "envio", "local", "db-migrate", "up"],
      {
        stdio: silent ? "ignore" : "inherit",
        cwd: process.cwd(),
      }
    );
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`db-migrate up exited with code ${code}`));
      }
    });
    child.on("error", reject);
  });

export const runMigrationsNoExit = () => spawnDbMigrateUp(false);
export const runMigrationsNoLogs = () => spawnDbMigrateUp(true);

export enum EventVariants {
  NftFactoryContract_SimpleNftCreatedEvent,
  SimpleNftContract_TransferEvent,
}
