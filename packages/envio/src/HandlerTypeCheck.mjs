import { execFile } from "node:child_process";
import { existsSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { stripVTControlCharacters } from "node:util";

const TIMEOUT_MINUTES = 10;

// tsc's pretty output reads the same from TypeScript 5 to 7: a diagnostic
// starts unindented with its location, and its code frame and related
// locations follow it, indented, until the next one or the closing summary.
const FILE_DIAGNOSTIC = /^(.+):\d+:\d+ - error TS\d+: /;
const GLOBAL_DIAGNOSTIC = /^error TS\d+: /;
const SUMMARY = /^Found \d+ errors?\b/;

const findUp = (directory, name) => {
  const candidate = path.join(directory, name);
  if (existsSync(candidate)) return candidate;
  const parent = path.dirname(directory);
  return parent === directory ? undefined : findUp(parent, name);
};

const realPath = (file) => {
  try {
    return realpathSync(file);
  } catch {
    return file;
  }
};

// The `tsc` the project's own scripts run. TypeScript 7 has no JavaScript API
// to call instead, only this command.
const resolveTsc = (cwd) => {
  try {
    const manifest = createRequire(path.join(cwd, "package.json")).resolve("typescript/package.json");
    const { bin } = JSON.parse(readFileSync(manifest, "utf8"));
    return path.resolve(path.dirname(manifest), typeof bin === "string" ? bin : bin.tsc);
  } catch {
    return undefined;
  }
};

const runTsc = (tsc, cwd, args) =>
  new Promise((resolve) =>
    execFile(
      process.execPath,
      [tsc, ...args],
      { cwd, timeout: TIMEOUT_MINUTES * 60 * 1000, maxBuffer: Infinity },
      (error, stdout, stderr) =>
        resolve({
          failed: error !== null,
          timedOut: error?.killed === true,
          output: stripVTControlCharacters(`${stdout}${stderr}`),
        })
    )
  );

const diagnosticsOf = (output, cwd) => {
  const diagnostics = [];
  let current;
  for (const line of output.split("\n")) {
    const location = FILE_DIAGNOSTIC.exec(line);
    if (location) {
      current = { file: realPath(path.resolve(cwd, location[1])), lines: [line] };
      diagnostics.push(current);
    } else if (GLOBAL_DIAGNOSTIC.test(line) || SUMMARY.test(line)) {
      current = undefined;
    } else {
      current?.lines.push(line);
    }
  }
  return diagnostics;
};

// Exit codes say nothing here: TypeScript 5 and 6 exit with 2 on type errors,
// 7 with 1, and 1 is also how its launcher fails when the native compiler
// isn't installed.
const failure = ({ timedOut, output }) => {
  if (timedOut) return `tsc didn't finish within ${TIMEOUT_MINUTES} minutes.`;
  const lines = output.split("\n");
  return lines.find((line) => /^\w*Error: /.test(line)) ?? output.trim();
};

const skipFailure = (result) => ({
  skipped: `Skipped the handler type check: TypeScript's tsc failed without reporting a type error:\n\n${failure(result)}`,
});

export const check = async (cwd, files) => {
  // The ReScript compiler checks a ReScript project's handlers, so it has no
  // reason to set up TypeScript, and the warning would only be noise there.
  // `rescript.json` at the root is what makes codegen treat it as ReScript.
  const skip = (warning) => (existsSync(path.join(cwd, "rescript.json")) ? {} : { skipped: warning });

  const tsc = resolveTsc(cwd);
  if (tsc === undefined) {
    return skip("Skipped the handler type check: the project doesn't depend on typescript.");
  }

  const tsconfig = findUp(cwd, "tsconfig.json");
  if (tsconfig === undefined) {
    return skip(
      "Skipped the handler type check: no tsconfig.json found. Add one to type-check handlers on start, like the one envio init creates."
    );
  }
  const projectDir = path.dirname(tsconfig);

  // The tsconfig's files stay roots, as tsc makes them, since any of them can
  // declare globals a handler relies on. Naming the handlers in `files` would
  // otherwise drop the default `include` of a tsconfig that sets none.
  const shown = await runTsc(tsc, cwd, ["--project", tsconfig, "--showConfig"]);
  let projectFiles;
  try {
    projectFiles = JSON.parse(shown.output).files ?? [];
  } catch {
    return skipFailure(shown);
  }

  const handlerFiles = files.map((file) => path.resolve(cwd, file));
  // Beside the user's tsconfig.json, as TypeScript 6 and 7 default `rootDir`
  // and look up `@types` from the directory of the config they run.
  const checkConfig = path.join(projectDir, `tsconfig.envio-check-${process.pid}.json`);
  writeFileSync(
    checkConfig,
    JSON.stringify({
      extends: `./${path.basename(tsconfig)}`,
      files: [...new Set([...projectFiles.map((file) => path.resolve(projectDir, file)), ...handlerFiles])],
      compilerOptions: { noEmit: true, incremental: false, composite: false },
    })
  );
  let result;
  try {
    result = await runTsc(tsc, cwd, ["--project", checkConfig, "--pretty"]);
  } finally {
    rmSync(checkConfig, { force: true });
  }

  // Only the handlers' errors count.
  const handlers = new Set(handlerFiles.map(realPath));
  const diagnostics = diagnosticsOf(result.output, cwd);
  const errors = diagnostics
    .filter(({ file }) => handlers.has(file))
    .map(({ lines }) => lines.join("\n").trimEnd());
  if (errors.length > 0) return { errors: errors.join("\n\n") };
  return result.failed && diagnostics.length === 0 ? skipFailure(result) : {};
};
