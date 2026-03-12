import { runUpMigrations } from "../../generated/src/db/Migrations.res.mjs";
import { makeClient } from "envio/src/PgStorage.gen";
import { unsafe, preparedUnsafe } from "envio/src/bindings/Postgres.res.mjs";

export const createSql = makeClient;
export { unsafe, preparedUnsafe };

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
