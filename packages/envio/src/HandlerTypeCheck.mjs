import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { stripVTControlCharacters } from "node:util";

const TIMEOUT_MINUTES = 10;

// tsc's pretty output reads the same from TypeScript 5 to 7: a diagnostic
// starts unindented with its location, its code frame and related locations
// follow indented, and `--listFiles` prints the program's files after the
// last one, before the closing summary.
const FILE_DIAGNOSTIC = /^(.+):\d+:\d+ - error TS\d+: /;
const GLOBAL_DIAGNOSTIC = /^error TS\d+: /;
const SUMMARY = /^Found \d+ errors?\b/;

const findUp = (directory, name) => {
  const candidate = path.join(directory, name);
  if (existsSync(candidate)) return candidate;
  const parent = path.dirname(directory);
  return parent === directory ? undefined : findUp(parent, name);
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

// Paths compare relative to the project, which on Windows also ignores the
// case of a drive letter tsc may print differently.
const parse = (output, cwd) => {
  const diagnostics = [];
  const programFiles = new Set();
  let current;
  for (const line of output.split(/\r?\n/)) {
    const location = FILE_DIAGNOSTIC.exec(line);
    if (location) {
      current = { file: path.relative(cwd, path.resolve(cwd, location[1])), lines: [line] };
      diagnostics.push(current);
    } else if (path.isAbsolute(line)) {
      programFiles.add(path.relative(cwd, line));
      current = undefined;
    } else if (GLOBAL_DIAGNOSTIC.test(line) || SUMMARY.test(line)) {
      current = undefined;
    } else {
      current?.lines.push(line);
    }
  }
  return { diagnostics, programFiles };
};

// Exit codes say nothing here: TypeScript 5 and 6 exit with 2 on type errors,
// 7 with 1, and 1 is also how its launcher fails when the native compiler
// isn't installed.
const failure = ({ timedOut, output }) => {
  if (timedOut) return `tsc didn't finish within ${TIMEOUT_MINUTES} minutes.`;
  return output.split(/\r?\n/).find((line) => /^\w*Error: /.test(line)) ?? output.trim();
};

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

  // The project's own `tsc --noEmit`, minus the build info it would write.
  const result = await runTsc(tsc, cwd, [
    "--project",
    tsconfig,
    "--noEmit",
    "--incremental",
    "false",
    "--composite",
    "false",
    "--listFiles",
    "--pretty",
  ]);
  const { diagnostics, programFiles } = parse(result.output, cwd);
  if (result.failed && diagnostics.length === 0) {
    return {
      skipped: `Skipped the handler type check: TypeScript's tsc failed without reporting a type error:\n\n${failure(result)}`,
    };
  }

  // Only the handlers' errors count.
  const handlers = files.map((file) => path.relative(cwd, file));
  const errors = diagnostics
    .filter(({ file }) => handlers.includes(file))
    .map(({ lines }) => lines.join("\n").trimEnd());
  if (errors.length > 0) return { errors: errors.join("\n\n") };

  const unchecked = handlers.filter((file) => !programFiles.has(file));
  return unchecked.length === 0
    ? {}
    : {
        skipped: `Skipped the handler type check for ${unchecked.join(", ")}: ${path.relative(cwd, tsconfig)} doesn't include ${
          unchecked.length === 1 ? "it" : "them"
        }.`,
      };
};
