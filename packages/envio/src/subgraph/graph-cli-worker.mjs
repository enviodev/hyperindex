// Runs one graph-cli command, as its own bin would, on the thread
// `graph-cli.ts` sized for it. Plain JavaScript: the TypeScript loader envio
// registers doesn't reach worker threads.
import { parentPort, workerData } from "node:worker_threads";
import path from "node:path";
import { pathToFileURL } from "node:url";

const { packageDir, command, argv } = workerData;

let ok = true;
try {
  const { default: Command } = await import(
    pathToFileURL(path.join(packageDir, "dist", "commands", `${command}.js`)).href
  );
  await Command.run(argv, packageDir);
  // A generation failure is reported through the exit code, not a throw.
  ok = process.exitCode === undefined || process.exitCode === 0;
} catch (error) {
  // oclif ends a successful command early by throwing an exit of 0.
  if (error?.oclif?.exit !== 0) {
    console.error(error?.message ?? error);
    ok = false;
  }
}
process.exitCode = 0;
parentPort.postMessage(ok);
