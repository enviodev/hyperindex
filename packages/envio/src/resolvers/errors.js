// The error a resolver throws when it wants the client to see something
// specific. Anything else a handler throws is reported as an internal failure
// with its message withheld, so this is the way to say more than that.
//
// envio-serve carries these extensions through to the operation's `errors`
// array unchanged, and a resolver's own `code` wins over serve's.

export class ResolverError extends Error {
  /**
   * @param {string} message
   * @param {{ code?: string, httpStatus?: number, extensions?: Record<string, unknown> }} [options]
   */
  constructor(message, options = {}) {
    super(message);
    this.name = "ResolverError";
    this.code = options.code ?? "INTERNAL_SERVER_ERROR";
    this.httpStatus = options.httpStatus;
    this.extensions = options.extensions;
  }

  toExtensions() {
    return {
      code: this.code,
      ...(this.httpStatus === undefined
        ? {}
        : { http: { status: this.httpStatus } }),
      ...this.extensions,
    };
  }
}
