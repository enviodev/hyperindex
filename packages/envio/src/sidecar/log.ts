import pino from "pino";
import pretty from "pino-pretty";

export type LogParams = Record<string, unknown> | Error;

/** Same shape as the `Logger` handlers get as `context.log`. */
export type SidecarLogger = {
  readonly debug: (message: string, params?: LogParams) => void;
  readonly info: (message: string, params?: LogParams) => void;
  readonly warn: (message: string, params?: LogParams) => void;
  readonly error: (message: string, params?: LogParams) => void;
};

export type LoggerOptions = {
  readonly level?: string;
  readonly pretty?: boolean;
  readonly destination?: pino.DestinationStream;
};

type Level = "debug" | "info" | "warn" | "error";

const write = (logger: pino.Logger, level: Level, message: string, params?: LogParams) => {
  if (params instanceof Error) {
    logger[level]({ err: params }, message);
  } else if (params !== undefined) {
    logger[level](params, message);
  } else {
    logger[level](message);
  }
};

export const toUserLogger = (logger: pino.Logger): SidecarLogger => ({
  debug: (message, params) => write(logger, "debug", message, params),
  info: (message, params) => write(logger, "info", message, params),
  warn: (message, params) => write(logger, "warn", message, params),
  error: (message, params) => write(logger, "error", message, params),
});

export const createRootLogger = (options: LoggerOptions = {}): pino.Logger => {
  const level = options.level ?? "info";
  const usePretty = options.pretty ?? (process.stdout.isTTY === true && process.env.ENVIO_SIDECAR_LOG_JSON !== "true");
  if (options.destination !== undefined) {
    return pino({ level }, options.destination);
  }
  if (usePretty) {
    return pino({ level }, pretty({ colorize: true, ignore: "pid,hostname" }));
  }
  return pino({ level });
};

export const silentLogger = (): pino.Logger => pino({ level: "silent" });
