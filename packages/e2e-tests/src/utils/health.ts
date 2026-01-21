/**
 * Health check utilities with exponential backoff
 */

export interface HealthCheckOptions {
  url: string;
  maxAttempts?: number;
  initialDelayMs?: number;
  maxDelayMs?: number;
  timeoutMs?: number;
}

export interface HealthCheckResult {
  success: boolean;
  attempts: number;
  totalTimeMs: number;
  error?: string;
}

/**
 * Wait for a health endpoint to become available with exponential backoff
 */
export async function waitForHealth(
  options: HealthCheckOptions
): Promise<HealthCheckResult> {
  const {
    url,
    maxAttempts = 60,
    initialDelayMs = 500,
    maxDelayMs = 5000,
    timeoutMs = 5000,
  } = options;

  const startTime = Date.now();
  let attempts = 0;
  let delay = initialDelayMs;

  while (attempts < maxAttempts) {
    attempts++;

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);

      const response = await fetch(url, {
        method: "GET",
        signal: controller.signal,
      });

      clearTimeout(timeout);

      if (response.ok) {
        return {
          success: true,
          attempts,
          totalTimeMs: Date.now() - startTime,
        };
      }
    } catch {
      // Connection refused or timeout - continue retrying
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
    error: `Health check failed after ${attempts} attempts`,
  };
}

/**
 * Wait for indexer to be healthy on port 9898
 */
export async function waitForIndexer(
  port: number = 9898,
  maxAttempts: number = 60
): Promise<HealthCheckResult> {
  return waitForHealth({
    url: `http://localhost:${port}/healthz`,
    maxAttempts,
    initialDelayMs: 500,
    maxDelayMs: 2000,
  });
}

/**
 * Wait for Hasura to be healthy
 */
export async function waitForHasura(
  port: number = 8080,
  maxAttempts: number = 60
): Promise<HealthCheckResult> {
  return waitForHealth({
    url: `http://localhost:${port}/healthz`,
    maxAttempts,
    initialDelayMs: 500,
    maxDelayMs: 2000,
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
