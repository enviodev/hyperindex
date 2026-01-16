/**
 * GraphQL polling utilities with exponential backoff
 */

export interface GraphQLClientOptions {
  endpoint?: string;
  adminSecret?: string;
}

export interface PollOptions<T> {
  query: string;
  variables?: Record<string, unknown>;
  validate: (data: T) => boolean;
  maxAttempts?: number;
  initialDelayMs?: number;
  maxDelayMs?: number;
  timeoutMs?: number;
}

export interface PollResult<T> {
  success: boolean;
  data?: T;
  attempts: number;
  totalTimeMs: number;
  error?: string;
  lastResponse?: unknown;
}

export class GraphQLClient {
  private endpoint: string;
  private adminSecret?: string;

  constructor(options: GraphQLClientOptions = {}) {
    this.endpoint = options.endpoint ?? "http://localhost:8080/v1/graphql";
    this.adminSecret = options.adminSecret ?? "testing";
  }

  /**
   * Execute a GraphQL query
   */
  async query<T>(
    query: string,
    variables?: Record<string, unknown>
  ): Promise<{ data?: T; errors?: Array<{ message: string }> }> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };

    if (this.adminSecret) {
      headers["x-hasura-admin-secret"] = this.adminSecret;
    }

    const response = await fetch(this.endpoint, {
      method: "POST",
      headers,
      body: JSON.stringify({ query, variables }),
    });

    return response.json();
  }

  /**
   * Poll GraphQL endpoint until validation passes or max attempts reached
   */
  async poll<T>(options: PollOptions<T>): Promise<PollResult<T>> {
    const {
      query,
      variables,
      validate,
      maxAttempts = 100,
      initialDelayMs = 500,
      maxDelayMs = 3000,
      timeoutMs = 120000,
    } = options;

    const startTime = Date.now();
    let attempts = 0;
    let delay = initialDelayMs;
    let lastResponse: unknown;
    let lastError: string | undefined;

    while (attempts < maxAttempts) {
      // Check overall timeout
      if (Date.now() - startTime > timeoutMs) {
        return {
          success: false,
          attempts,
          totalTimeMs: Date.now() - startTime,
          error: `Timeout after ${timeoutMs}ms`,
          lastResponse,
        };
      }

      attempts++;

      try {
        const result = await this.query<T>(query, variables);
        lastResponse = result;

        if (result.errors) {
          lastError = result.errors.map((e) => e.message).join(", ");
        } else if (result.data) {
          if (validate(result.data)) {
            return {
              success: true,
              data: result.data,
              attempts,
              totalTimeMs: Date.now() - startTime,
            };
          }
        }
      } catch (err) {
        lastError = err instanceof Error ? err.message : String(err);
      }

      if (attempts < maxAttempts) {
        await sleep(delay);
        delay = Math.min(delay * 1.5, maxDelayMs);
      }
    }

    return {
      success: false,
      attempts,
      totalTimeMs: Date.now() - startTime,
      error: lastError ?? `Validation failed after ${attempts} attempts`,
      lastResponse,
    };
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Default client instance
export const graphql = new GraphQLClient();
