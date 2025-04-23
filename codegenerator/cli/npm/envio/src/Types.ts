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

export abstract class Effect<I, O> {
  protected opaque!: I | O;
}

export type EffectCaller = <I, O>(effect: Effect<I, O>, input: I) => Promise<O>;

export type EffectContext = {
  /**
   * Access the logger instance with event as a context. The logs will be displayed in the console and Envio Hosted Service.
   */
  readonly log: Logger;
  /**
   * Call the provided Effect with the given input.
   * Effects are the best for external calls with automatic deduplication, error handling and caching.
   * Define a new Effect using createEffect outside of the handler.
   */
  readonly effect: EffectCaller;
};
