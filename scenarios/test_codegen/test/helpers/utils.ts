import { Pool } from "pg";
import { runUpMigrations } from "../../generated/src/db/Migrations.res.mjs";

export const createSql = () =>
  new Pool({
    host: process.env.ENVIO_PG_HOST ?? "localhost",
    port: parseInt(process.env.ENVIO_PG_PORT ?? "5433"),
    user: process.env.ENVIO_PG_USER ?? "postgres",
    password: process.env.ENVIO_PG_PASSWORD ?? "testing",
    database: process.env.ENVIO_PG_DATABASE ?? "envio-dev",
  });

export const unsafe = (pool: Pool, text: string): Promise<any[]> =>
  pool.query(text).then((r) => r.rows);

export const preparedUnsafe = (
  pool: Pool,
  text: string,
  values: unknown
): Promise<any[]> => pool.query({ text, values } as any).then((r: any) => r.rows);

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
