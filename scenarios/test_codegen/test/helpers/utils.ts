import {
  runDownMigrations,
  runUpMigrations,
} from "../../generated/src/db/Migrations.bs";
import Postgres from "postgres";
import { config } from "../../generated/src/db/Db.bs";

export const createSql = () =>
  Postgres(
    `postgres://${config.username}:${config.password}@${config.host}:${config.port}/${config.database}?search_path=${config.schema}`,
    config,
  );

const originalConsoleLog = console.log;

export const disableConsoleLog = () => {
  console.log = () => undefined;
};

export const enableConsoleLog = () => {
  console.log = originalConsoleLog;
};

export const runMigrationsNoExit = async () => {
  await runDownMigrations(false);
  await runUpMigrations(false);
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
