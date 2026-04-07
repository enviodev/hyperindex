import { makeClient } from "envio/src/PgStorage.gen";

export const createSql = makeClient;

// Migrations are now run exactly once for the whole test session via
// vitest's globalSetup (see test/global-setup.ts). These helpers are kept
// as no-ops so existing tests that call them in beforeAll/afterAll keep
// compiling without spawning a per-file migration subprocess.
export const runMigrationsNoExit = async () => {};
export const runMigrationsNoLogs = async () => {};

export enum EventVariants {
  NftFactoryContract_SimpleNftCreatedEvent,
  SimpleNftContract_TransferEvent,
}
