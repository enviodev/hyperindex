/**
 * Process management utilities for indexer and Docker
 */

import { spawn, exec, ChildProcess } from "child_process";
import { createConnection } from "net";
import { promisify } from "util";

const execAsync = promisify(exec);

/** Strip npm/pnpm env vars that interfere when spawned processes call `node` */
function cleanEnv(extra?: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    const lower = k.toLowerCase();
    if (lower.startsWith("npm_") || lower.startsWith("pnpm_")) continue;
    env[k] = v;
  }
  return { ...env, ...extra };
}

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
 * Run a command and wait for completion.
 * stdout/stderr are captured and also forwarded to the console.
 */
export async function runCommand(
  command: string,
  args: string[],
  options: SpawnOptions
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    const env = cleanEnv(options.env);
    const child = spawn(command, args, {
      cwd: options.cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (data) => {
      const s = data.toString();
      stdout += s;
      process.stdout.write(s);
    });

    child.stderr?.on("data", (data) => {
      const s = data.toString();
      stderr += s;
      process.stderr.write(s);
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
 * Start a background process with output forwarded to the console.
 * Uses piped stdio so callers can also monitor stdout/stderr streams.
 */
export function startBackground(
  command: string,
  args: string[],
  options: SpawnOptions
): ChildProcess {
  const env = cleanEnv(options.env);
  const child = spawn(command, args, {
    cwd: options.cwd,
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: false,
  });

  child.stdout?.on("data", (data) => process.stdout.write(data));
  child.stderr?.on("data", (data) => process.stderr.write(data));

  return child;
}

/**
 * Wait for a specific string to appear in a process's stdout or stderr.
 * Resolves when the pattern is found or process exits with code 0.
 * Rejects on timeout or non-zero exit.
 */
export function waitForOutput(
  child: ChildProcess,
  pattern: string,
  timeoutMs: number
): Promise<void> {
  return new Promise((resolve, reject) => {
    const onData = (data: Buffer) => {
      if (data.toString().includes(pattern)) {
        cleanup();
        resolve();
      }
    };

    const onClose = (code: number | null) => {
      cleanup();
      if (code === 0) resolve();
      else reject(new Error(`Process exited with code ${code}`));
    };

    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for "${pattern}" after ${timeoutMs}ms`));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      child.stdout?.off("data", onData);
      child.stderr?.off("data", onData);
      child.off("close", onClose);
    }

    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);
    child.on("close", onClose);
  });
}

/**
 * Check if a port is available by attempting a TCP connection.
 */
export function isPortAvailable(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ port, host: "127.0.0.1" });
    socket.once("connect", () => {
      socket.destroy();
      resolve(false);
    });
    socket.once("error", () => {
      socket.destroy();
      resolve(true);
    });
  });
}

/**
 * Kill whatever is listening on a port using lsof + kill.
 * Falls back gracefully if lsof/kill aren't available.
 */
export async function killProcessOnPort(port: number): Promise<boolean> {
  if (await isPortAvailable(port)) return false;

  try {
    const { stdout } = await execAsync(`lsof -t -i :${port}`);
    const pids = stdout.trim().split("\n").filter(Boolean);
    for (const pid of pids) {
      try {
        process.kill(Number(pid), "SIGKILL");
      } catch {
        // Process may have already exited
      }
    }
  } catch {
    // lsof not available or no process found
  }

  // Wait up to 5s for the port to actually free up
  for (let i = 0; i < 10; i++) {
    await sleep(500);
    if (await isPortAvailable(port)) return true;
  }
  return false;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

