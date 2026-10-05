import { createRequire } from "node:module";
import path from "node:path";
import { stripVTControlCharacters } from "node:util";
import { parentPort, workerData } from "node:worker_threads";

const toPosix = (file) => file.split(path.sep).join("/");

const check = ({ cwd, files }) => {
  let ts;
  try {
    // The project's own compiler, so handlers are checked exactly as the
    // user's editor and `tsc` check them.
    ts = createRequire(path.join(cwd, "package.json"))("typescript");
  } catch {
    return { skipped: "the project doesn't depend on typescript" };
  }

  const configPath = ts.findConfigFile(cwd, ts.sys.fileExists);
  if (configPath === undefined) {
    return { skipped: "no tsconfig.json was found" };
  }

  const host = {
    getCanonicalFileName: (file) => file,
    getCurrentDirectory: () => toPosix(cwd),
    getNewLine: () => "\n",
  };
  const format = (diagnostics) =>
    stripVTControlCharacters(ts.formatDiagnosticsWithColorAndContext(diagnostics, host)).trimEnd();

  let configError;
  const parsed = ts.getParsedCommandLineOfConfigFile(
    configPath,
    { noEmit: true },
    { ...ts.sys, onUnRecoverableConfigFileDiagnostic: (diagnostic) => (configError = diagnostic) }
  );
  if (parsed === undefined) {
    return { errors: format([configError]) };
  }

  const handlerFiles = files.map((file) => toPosix(path.resolve(cwd, file)));
  // Declaration files carry the globals handlers rely on, `envio-env.d.ts`
  // among them. Other files come in only through a handler's imports, so the
  // program doesn't parse the whole project.
  const declarationFiles = parsed.fileNames.filter((file) => /\.d\.[cm]?ts$/.test(file));
  const program = ts.createProgram({
    rootNames: [...declarationFiles, ...handlerFiles],
    options: parsed.options,
    projectReferences: parsed.projectReferences,
  });

  const diagnostics = handlerFiles.flatMap((file) => {
    const sourceFile = program.getSourceFile(file);
    return sourceFile === undefined
      ? []
      : [...program.getSyntacticDiagnostics(sourceFile), ...program.getSemanticDiagnostics(sourceFile)];
  });
  return diagnostics.length === 0 ? {} : { errors: format(diagnostics) };
};

parentPort.postMessage(check(workerData));
