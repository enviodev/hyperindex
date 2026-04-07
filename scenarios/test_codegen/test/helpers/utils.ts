// Import from the compiled .res.mjs directly. The .gen.ts re-export
// can't be used here because Node 24 refuses to strip TypeScript types
// from files inside node_modules.
import { makeClient } from "envio/src/PgStorage.res.mjs";

export const createSql = makeClient as () => any;

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
