import { describe, it } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import * as Core from "envio/src/Core.res.mjs";
import * as Config from "envio/src/Config.res.mjs";
import * as HandlerRegister from "envio/src/HandlerRegister.res.mjs";
import { checkSources } from "./TypeChecker.ts";

const helperFile = fileURLToPath(import.meta.url);
const tmpDir = path.join(path.dirname(helperFile), "..", ".tmp");

/**
 * `file:line` of the `defineIndexerTest` call, used to name the suite so a
 * failure points at the fixture that produced it. The first stack frame outside
 * this helper is the caller.
 */
function callSite(): string {
  const stack = new Error().stack ?? "";
  for (const raw of stack.split("\n").slice(1)) {
    const match = raw.match(/\(?([^()\s]+):(\d+):(\d+)\)?\s*$/);
    if (match === null) continue;
    const file = match[1]!;
    if (file.startsWith("node:") || file.includes("defineIndexerTest")) continue;
    return `${path.basename(file)}:${match[2]}`;
  }
  return "unknown";
}

// Written under `test/` so vite-node transforms them and their bare `envio`
// import resolves to the same instance the harness loaded. Never deleted after
// import: vitest renders code frames from these paths when a test fails, so the
// files must outlive the run. `globalSetup` clears the directory beforehand.
function writeModule(kind: string, site: string, source: string): string {
  const slug = site.replace(/[^a-zA-Z0-9]+/g, "-");
  const file = path.join(tmpDir, `${slug}-${kind}-${randomUUID().slice(0, 8)}.ts`);
  fs.writeFileSync(file, source);
  return file;
}

// Config priming and the handler registry are process-global, so one fixture
// owns the process. Under `pool: "forks"` that means one fixture per file.
let definedAt: string | undefined;

export type IndexerTestFixture = {
  /** Suite name; defaults to the `defineIndexerTest` call site. */
  name?: string;
  configYaml: string;
  schema?: string;
  /** Handler module source, exactly as a user's `src/handlers/*.ts`. */
  handlers: string;
  /** Test module source, exactly as a user's `src/indexer.test.ts`. */
  test: string;
};

/**
 * Run a user-facing test module against a config parsed from YAML, with no
 * codegen'd project on disk. Both `handlers` and `test` are type-checked
 * against the config's generated `.envio/types.d.ts`, then evaluated: the
 * handlers register into the normal global registry, and the test module's
 * `it()` calls register into the calling file's suite, so they get real vitest
 * names, code frames and diffs.
 *
 * Must be called with top-level `await` from a `.test.ts` file — the imported
 * tests only register while the caller is being collected.
 */
export async function defineIndexerTest(fixture: IndexerTestFixture): Promise<void> {
  const site = callSite();
  const name = fixture.name ?? `indexerTest(${site})`;
  try {
    if (definedAt !== undefined) {
      throw new Error(
        `defineIndexerTest was already called at ${definedAt}. The parsed config and handler ` +
          `registry are process-global, so each fixture needs its own test file.`,
      );
    }
    definedAt = site;

    const parsed = Core.fromUserApi(
      fixture.schema,
      undefined,
      undefined,
      true,
      fixture.configYaml,
    );
    const typesDts = parsed.indexerTypes;
    if (typesDts === null || typesDts === undefined) {
      throw new Error("Config parsed without generated indexer types.");
    }

    const errors = checkSources(typesDts, {
      handlers: fixture.handlers,
      test: fixture.test,
    });
    if (errors.length > 0) {
      throw new Error(`Type errors:\n${errors.join("\n")}`);
    }

    const publicConfigJson = JSON.parse(parsed.config);
    // Makes `Config.load()` resolve to this fixture, which is what lets the
    // real `createTestIndexer` from "envio" run with no project on disk.
    Config.prime(publicConfigJson);
    HandlerRegister.startRegistration(Config.fromPublic(publicConfigJson));

    fs.mkdirSync(tmpDir, { recursive: true });
    await import(writeModule("handlers", site, fixture.handlers));

    const testFile = writeModule("test", site, fixture.test);
    await describe(name, async () => {
      await import(testFile);
    });
  } catch (error) {
    // Surface setup failures as a named test rather than a collection crash,
    // so the reporter attributes them to this fixture.
    it(`${name} setup`, () => {
      throw error;
    });
  }
}
