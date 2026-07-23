import ts from "typescript";
import { fileURLToPath } from "node:url";
import * as path from "node:path";

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

/**
 * Type-check `handlers` against the generated `.envio/types.d.ts` of a mock
 * config. Returns human-readable error strings; an empty array means the
 * handlers type-check cleanly.
 *
 * The two inputs are injected as virtual sibling files of this module so bare
 * imports (`envio`, `ts-expect`, ...) resolve through envio-tests'
 * node_modules, and the generated `declare module "envio"` augmentation binds
 * `indexer` to the mock config for this program only — no shared global state,
 * so independent configs never collide.
 */
export function checkHandlerTypes(typesDts: string, handlers: string): string[] {
  const typesPath = path.join(helpersDir, "__mock_indexer_types.d.ts");
  const handlersPath = path.join(helpersDir, "__mock_indexer_handlers.ts");

  const virtualFiles = new Map<string, string>([
    [typesPath, typesDts],
    [handlersPath, handlers],
  ]);

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
      return ts.createSourceFile(fileName, virtual, languageVersionOrOptions, true);
    }
    return baseGetSourceFile(fileName, languageVersionOrOptions, onError, shouldCreate);
  };

  const program = ts.createProgram([typesPath, handlersPath], compilerOptions, host);

  // Report errors from the handler + generated-types files and global config
  // errors (no associated file). node_modules noise is dropped; lib .d.ts
  // errors are already suppressed by skipLibCheck.
  const diagnostics = ts
    .getPreEmitDiagnostics(program)
    .filter((d) => d.file === undefined || virtualFiles.has(d.file.fileName));

  return diagnostics.map((d) => ts.formatDiagnostic(d, formatHost).trim());
}
