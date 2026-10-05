import { createRequire } from "node:module";
import path from "node:path";
import { stripVTControlCharacters } from "node:util";
import { parentPort, workerData } from "node:worker_threads";

const check = ({ cwd, files }) => {
  let ts;
  try {
    // The project's own compiler, so handlers are checked exactly as the
    // user's editor and `tsc` check them.
    ts = createRequire(path.join(cwd, "package.json"))("typescript");
  } catch {
    return { skipped: "Skipped the handler type check: the project doesn't depend on typescript." };
  }

  const configPath = ts.findConfigFile(cwd, ts.sys.fileExists);
  if (configPath === undefined) {
    return {
      skipped:
        "Skipped the handler type check: no tsconfig.json found. Add one to type-check handlers on start, like the one envio init creates.",
    };
  }

  const host = {
    getCanonicalFileName: (file) => file,
    getCurrentDirectory: () => cwd,
    getNewLine: () => "\n",
  };
  const format = (diagnostics) =>
    stripVTControlCharacters(ts.formatDiagnosticsWithColorAndContext(diagnostics, host)).trimEnd();

  const parsed = ts.getParsedCommandLineOfConfigFile(
    configPath,
    { noEmit: true },
    {
      ...ts.sys,
      onUnRecoverableConfigFileDiagnostic: (diagnostic) => {
        throw new Error(format([diagnostic]));
      },
    }
  );

  const handlerFiles = files.map((file) => path.resolve(cwd, file));
  // Declaration files carry the globals handlers rely on, `envio-env.d.ts`
  // among them. Other files come in only through a handler's imports, so the
  // program doesn't parse the whole project.
  const program = ts.createProgram({
    rootNames: [...parsed.fileNames.filter((file) => /\.d\.[cm]?ts$/.test(file)), ...handlerFiles],
    options: parsed.options,
    projectReferences: parsed.projectReferences,
  });

  // Every file is a root, so each has a source file. Without one,
  // `getSemanticDiagnostics` would check the whole program.
  const diagnostics = handlerFiles
    .map((file) => program.getSourceFile(file))
    .flatMap((sourceFile) => [
      ...program.getSyntacticDiagnostics(sourceFile),
      ...program.getSemanticDiagnostics(sourceFile),
    ]);
  return diagnostics.length === 0 ? {} : { errors: format(diagnostics) };
};

parentPort.postMessage(check(workerData));
