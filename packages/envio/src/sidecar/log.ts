import ecsFormat from "@elastic/ecs-pino-format";
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
  /** ECS JSON (`@timestamp`, `ecs.version`, `log.level`, `message`); wins over `pretty`. */
  readonly ecs?: boolean;
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

const PINO_LEVELS = new Set(["trace", "debug", "info", "warn", "error", "fatal", "silent"]);

// The indexer's LOG_LEVEL also takes `udebug | uinfo | uwarn | uerror` (its user
// log levels, Env.res). Every sidecar log line is user code or about it, so each
// maps to its base level. Pino throws on a level it does not know, which would
// stop the sidecar from starting over a log setting.
export const resolveLogLevel = (raw: string | undefined): { level: string; unknown?: string } => {
  if (raw === undefined) return { level: "info" };
  const name = raw.trim().toLowerCase();
  const base = /^u(debug|info|warn|error)$/.exec(name)?.[1] ?? name;
  return PINO_LEVELS.has(base) ? { level: base } : { level: "info", unknown: raw };
};

export const createRootLogger = (options: LoggerOptions = {}): pino.Logger => {
  const { level, unknown } = resolveLogLevel(options.level);
  // The indexer's options under LOG_STRATEGY=ecs-* (Logging.res): an empty base
  // drops pid and hostname. Alloy's id-pods pipeline reads the top level
  // `log.level` and `ecs.version` keys to label the line.
  const pinoOptions: pino.LoggerOptions = options.ecs === true ? { ...ecsFormat(), base: {}, level } : { level };
  const usePretty =
    options.ecs !== true &&
    (options.pretty ?? (process.stdout.isTTY === true && process.env.ENVIO_SIDECAR_LOG_JSON !== "true"));
  const logger =
    options.destination !== undefined
      ? pino(pinoOptions, options.destination)
      : usePretty
        ? pino(pinoOptions, pretty({ colorize: true, ignore: "pid,hostname" }))
        : pino(pinoOptions);
  if (unknown !== undefined) logger.warn(`ENVIO_SIDECAR_LOG_LEVEL '${unknown}' is not a known level, using 'info'`);
  return logger;
};

export const silentLogger = (): pino.Logger => pino({ level: "silent" });
