import { Worker } from "node:worker_threads";

// The compiler blocks the thread it runs on, so it gets its own and the
// database setup carries on meanwhile.
export const check = (cwd, files) =>
  new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./HandlerTypeCheckWorker.mjs", import.meta.url), {
      workerData: { cwd, files },
    });
    worker.once("message", resolve);
    worker.once("error", reject);
    worker.once("exit", (code) => {
      if (code !== 0) reject(new Error(`The handler type check exited with code ${code}.`));
    });
  });
