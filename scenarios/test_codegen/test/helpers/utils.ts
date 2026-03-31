import { runUpMigrations } from "envio/src/Migrations.res.mjs";
import { makeClient } from "envio/src/PgStorage.gen";
import { Generated } from "../../generated/src/Indexer.res.mjs";

export const createSql = makeClient;

const originalConsoleLog = console.log;

export const disableConsoleLog = () => {
  console.log = () => undefined;
};

export const enableConsoleLog = () => {
  console.log = originalConsoleLog;
};

export const runMigrationsNoExit = async () => {
  await runUpMigrations(Generated.codegenPersistence, Generated.configWithoutRegistrations, false, true);
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
