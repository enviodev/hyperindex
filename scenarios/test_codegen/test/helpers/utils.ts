import { runUpMigrations } from "../../generated/src/db/Migrations.res.js";
import Postgres from "postgres";
import { config } from "../../generated/src/db/Db.res.js";

export const createSql = () => Postgres(config);

const originalConsoleLog = console.log;

export const disableConsoleLog = () => {
  console.log = () => undefined;
};

export const enableConsoleLog = () => {
  console.log = originalConsoleLog;
};

export const runMigrationsNoExit = async () => {
  await runUpMigrations(false, true);
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
