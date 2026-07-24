import ts from "typescript";
import { fileURLToPath } from "node:url";
import * as path from "node:path";

// Must match the TypeScript version the init templates pin
// (packages/cli/src/hbs_templating/init_templates.rs), so handlers are checked
// with the exact compiler a real project runs. Bump both together.
const EXPECTED_TS_VERSION = "6.0.3";
if (ts.version !== EXPECTED_TS_VERSION) {
  throw new Error(
    `TypeChecker expects TypeScript ${EXPECTED_TS_VERSION} to match the init-template pin ` +
      `in packages/cli/src/hbs_templating/init_templates.rs, but resolved ${ts.version}. ` +
      `Update both together.`,
  );
}

// Mirrors packages/cli/templates/static/*/typescript/tsconfig.json (identical
// across every init template), so handlers are checked exactly as a real
// project's would be. Kept as the same JSON tsc itself parses, then converted
// through the compiler API so the enum mapping can't drift from a hand-rolled
// one.
const TSCONFIG_COMPILER_OPTIONS = {
  esModuleInterop: true,
  skipLibCheck: true,
  target: "es2022",
  allowJs: true,
  resolveJsonModule: true,
  moduleDetection: "force",
  isolatedModules: true,
  verbatimModuleSyntax: true,
  strict: true,
  noUncheckedIndexedAccess: true,
  noImplicitOverride: true,
  module: "ESNext",
  moduleResolution: "bundler",
  noEmit: true,
  lib: ["es2022"],
  types: ["node"],
};

const helpersDir = path.dirname(fileURLToPath(import.meta.url));

const { options: compilerOptions, errors: optionErrors } =
  ts.convertCompilerOptionsFromJson(TSCONFIG_COMPILER_OPTIONS, helpersDir);
if (optionErrors.length > 0) {
  throw new Error(
    "Invalid TypeChecker compiler options: " +
      optionErrors
        .map((e) => ts.flattenDiagnosticMessageText(e.messageText, "\n"))
        .join("\n"),
  );
}

const formatHost: ts.FormatDiagnosticsHost = {
  getCanonicalFileName: (f) => f,
  getCurrentDirectory: () => helpersDir,
  getNewLine: () => "\n",
};

const typesPath = path.join(helpersDir, "__mock_indexer_types.d.ts");
const handlersPath = path.join(helpersDir, "__mock_indexer_handlers.ts");

// The virtual inputs for the current call, injected as sibling files of this
// module so bare imports (`envio`, `ts-expect`, ...) resolve through
// envio-tests' node_modules, and the generated `declare module "envio"`
// augmentation binds `indexer` to this fixture's config for this program only —
// no shared global state, so independent configs never collide.
let virtualFiles = new Map<string, string>();

// The `envio`/`@types/node`/lib `.d.ts` graph is identical across fixtures, so
// parse it once and reuse the SourceFiles (and the prior program's structure)
// across calls — otherwise each fixture re-parses megabytes of declarations.
// Only the two virtual files are re-read every call.
const sourceFileCache = new Map<string, ts.SourceFile>();
let previousProgram: ts.Program | undefined;

const host = ts.createCompilerHost(compilerOptions, true);
// Anchor resolution to this package so `types: ["node"]` (and any other
// type-root lookup) finds envio-tests' `@types/node` regardless of which
// package's cwd launched the test — otherwise a caller without `@types/node`
// reachable from its cwd gets a spurious global TS2688.
host.getCurrentDirectory = () => helpersDir;
const baseReadFile = host.readFile.bind(host);
const baseFileExists = host.fileExists.bind(host);
const baseGetSourceFile = host.getSourceFile.bind(host);

host.readFile = (fileName) => virtualFiles.get(fileName) ?? baseReadFile(fileName);
host.fileExists = (fileName) =>
  virtualFiles.has(fileName) || baseFileExists(fileName);
host.getSourceFile = (fileName, languageVersionOrOptions, onError, shouldCreate) => {
  const virtual = virtualFiles.get(fileName);
  if (virtual !== undefined) {
    // Fresh every call — the fixture's types/handlers differ, and returning a
    // new SourceFile is what tells the reused program these two files changed.
    return ts.createSourceFile(fileName, virtual, languageVersionOrOptions, true);
  }
  const cached = sourceFileCache.get(fileName);
  if (cached !== undefined) return cached;
  const sourceFile = baseGetSourceFile(fileName, languageVersionOrOptions, onError, shouldCreate);
  if (sourceFile !== undefined) sourceFileCache.set(fileName, sourceFile);
  return sourceFile;
};

/**
 * Type-check `handlers` against the generated `.envio/types.d.ts` of a mock
 * config. Returns human-readable error strings; an empty array means the
 * handlers type-check cleanly.
 */
export function checkHandlerTypes(typesDts: string, handlers: string): string[] {
  virtualFiles = new Map<string, string>([
    [typesPath, typesDts],
    [handlersPath, handlers],
  ]);

  const program = ts.createProgram(
    [typesPath, handlersPath],
    compilerOptions,
    host,
    previousProgram,
  );
  previousProgram = program;

  // Only diagnostics inferred in the handler source are of interest — the
  // generated types are a `.d.ts` we trust (and skipLibCheck skips anyway). We
  // keep file-less diagnostics too, since those are global config/harness
  // errors (e.g. a missing `@types/node`) that must not be silently swallowed.
  const diagnostics = ts
    .getPreEmitDiagnostics(program)
    .filter((d) => d.file === undefined || d.file.fileName === handlersPath);

  return diagnostics.map((d) => ts.formatDiagnostic(d, formatHost).trim());
}
