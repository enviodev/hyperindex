/**
 * Process management utilities for indexer and Docker
 */

import { spawn, exec, ChildProcess } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

export interface ProcessResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface SpawnOptions {
  cwd: string;
  env?: Record<string, string>;
  timeout?: number;
}

/**
 * Run a command and wait for completion
 */
export async function runCommand(
  command: string,
  args: string[],
  options: SpawnOptions
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, ...options.env };
    const child = spawn(command, args, {
      cwd: options.cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (data) => {
      stdout += data.toString();
    });

    child.stderr?.on("data", (data) => {
      stderr += data.toString();
    });

    const timeoutId = options.timeout
      ? setTimeout(() => {
          child.kill("SIGTERM");
          reject(new Error(`Command timed out after ${options.timeout}ms`));
        }, options.timeout)
      : null;

    child.on("close", (code) => {
      if (timeoutId) clearTimeout(timeoutId);
      resolve({
        exitCode: code ?? 1,
        stdout,
        stderr,
      });
    });

    child.on("error", (err) => {
      if (timeoutId) clearTimeout(timeoutId);
      reject(err);
    });
  });
}

/**
 * Start a background process
 */
export function startBackground(
  command: string,
  args: string[],
  options: SpawnOptions
): ChildProcess {
  const env = { ...process.env, ...options.env };
  const child = spawn(command, args, {
    cwd: options.cwd,
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: false,
  });

  return child;
}

/**
 * Kill process on a specific port
 */
export async function killProcessOnPort(port: number): Promise<boolean> {
  try {
    const { stdout } = await execAsync(`lsof -t -i :${port}`);
    const pids = stdout.trim().split("\n").filter(Boolean);

    for (const pid of pids) {
      try {
        await execAsync(`kill -9 ${pid}`);
      } catch {
        // Process may have already exited
      }
    }

    return pids.length > 0;
  } catch {
    // No process on port
    return false;
  }
}

/**
 * Check if a port is available
 */
export async function isPortAvailable(port: number): Promise<boolean> {
  try {
    await execAsync(`lsof -i :${port}`);
    return false;
  } catch {
    return true;
  }
}

/**
 * Wait for a port to become available
 */
export async function waitForPortFree(
  port: number,
  maxAttempts: number = 30
): Promise<boolean> {
  for (let i = 0; i < maxAttempts; i++) {
    if (await isPortAvailable(port)) {
      return true;
    }
    await sleep(1000);
  }
  return false;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
