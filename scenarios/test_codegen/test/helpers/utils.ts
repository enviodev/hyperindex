import {
  runDownMigrations,
  runUpMigrations,
} from "../../generated/src/Migrations.bs";
import Postgres from "postgres";
import { db } from "../../generated/src/Config.bs";
export const createSql = () => Postgres(db);

const originalConsoleLog = console.log;

export const disableConsoleLog = () => {
  console.log = () => undefined;
};

export const enableConsoleLog = () => {
  console.log = originalConsoleLog;
};

export const runMigrationsNoExit = async () => {
  await runDownMigrations();
  await runUpMigrations();
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
