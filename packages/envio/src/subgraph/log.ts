/**
 * The logger the subgraph runtime writes its own lines through: the one the
 * indexer hands it at registration. A line logged before that (codegen run
 * ahead of a start) goes to stderr.
 */

import { info as loggerInfo, warn as loggerWarn } from "../Logger.res.mjs";
import { notify } from "../SubgraphLog.res.mjs";

export { notify };

let logger: unknown;

export function setLogger(next: unknown): void {
  logger = next;
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
