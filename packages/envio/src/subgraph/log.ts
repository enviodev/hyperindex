/**
 * The logger the subgraph runtime writes its own lines through: the one the
 * indexer hands it at registration. A line logged before that (codegen run
 * ahead of a start) goes to stderr.
 */

import { info as loggerInfo, warn as loggerWarn } from "../Logger.res.mjs";

let logger: unknown;

export function setLogger(next: unknown): void {
  logger = next;
}

type Listener = (level: string, message: string) => void;

const listeners = new Set<Listener>();

/**
 * Every line the runtime logs, and every line a mapping logs through graph-ts
 * (`uinfo`, `uwarn`, ...), as it is logged. A test indexer's own logger is
 * silent, so this is how a test reads them.
 */
export function onLog(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function notify(level: string, message: string): void {
  for (const listener of listeners) listener(level, message);
}

export function info(message: string): void {
  notify("info", message);
  if (logger) loggerInfo(logger, message, undefined);
  else process.stderr.write(`${message}\n`);
}

export function warn(message: string): void {
  notify("warn", message);
  if (logger) loggerWarn(logger, message, undefined);
  else process.stderr.write(`${message}\n`);
}
