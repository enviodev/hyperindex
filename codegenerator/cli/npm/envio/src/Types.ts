export type Invalid = never;

export type Address = string;

export type Logger = {
  readonly debug: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly info: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly warn: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly error: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
};
