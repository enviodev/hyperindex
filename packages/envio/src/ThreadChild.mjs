// Prototype: a worker thread dressed as the forked child the supervisor
// already drives, so both layouts run through the same supervisor code.
import { Worker } from "node:worker_threads";
import { EventEmitter } from "node:events";

export function spawnThread(entryPath, env) {
  const worker = new Worker(entryPath, { env, argv: [] });
  const child = new EventEmitter();
  child.connected = true;
  child.stdout = null;
  child.stderr = null;
  child.send = (message) => {
    if (!child.connected) return false;
    worker.postMessage(message);
    return true;
  };
  child.kill = () => {
    worker.terminate();
    return true;
  };
  worker.on("message", (message) => child.emit("message", message));
  worker.on("error", (error) => child.emit("error", error));
  worker.on("exit", (code) => {
    child.connected = false;
    child.emit("exit", code, null);
    child.emit("close", code, null);
  });
  return child;
}
