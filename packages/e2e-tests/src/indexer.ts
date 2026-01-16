/**
 * Indexer lifecycle management
 */

import { ChildProcess } from "child_process";
import path from "path";
import { TestConfig, IndexerContext } from "./types.js";
import {
  runCommand,
  startBackground,
  killProcessOnPort,
  waitForPortFree,
} from "./utils/process.js";
import { waitForIndexer, waitForHasura } from "./utils/health.js";

const DEFAULT_PORT = 9898;
const HASURA_PORT = 8080;

export interface IndexerManagerOptions {
  /** Base directory for generated templates */
  outputDir: string;
  /** Path to envio CLI (default: pnpm envio) */
  envioCli?: string;
  /** Indexer port (default: 9898) */
  port?: number;
}

export class IndexerManager {
  private outputDir: string;
  private envioCli: string;
  private port: number;
  private currentProcess: ChildProcess | null = null;

  constructor(options: IndexerManagerOptions) {
    this.outputDir = options.outputDir;
    this.envioCli = options.envioCli ?? "pnpm envio";
    this.port = options.port ?? DEFAULT_PORT;
  }

  /**
   * Get the working directory for a test
   */
  getWorkDir(config: TestConfig): string {
    return path.join(
      this.outputDir,
      `${config.ecosystem}_${config.template}`,
      "TypeScript"
    );
  }

  /**
   * Install dependencies for a template
   */
  async install(config: TestConfig): Promise<void> {
    const workDir = this.getWorkDir(config);
    console.log(`[${config.id}] Installing dependencies...`);

    const result = await runCommand("pnpm", ["install"], {
      cwd: workDir,
      timeout: 120000,
    });

    if (result.exitCode !== 0) {
      throw new Error(`pnpm install failed: ${result.stderr}`);
    }
  }

  /**
   * Generate code for a template
   */
  async codegen(config: TestConfig): Promise<void> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";
    console.log(`[${config.id}] Running codegen...`);

    const [cmd, ...args] = this.envioCli.split(" ");
    const result = await runCommand(cmd!, [...args, "codegen", "--config", configFile], {
      cwd: workDir,
      timeout: 60000,
    });

    if (result.exitCode !== 0) {
      throw new Error(`codegen failed: ${result.stderr}`);
    }
  }

  /**
   * Stop any running indexer
   */
  async stop(config: TestConfig): Promise<void> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";
    console.log(`[${config.id}] Stopping existing indexer...`);

    const [cmd, ...args] = this.envioCli.split(" ");
    try {
      await runCommand(cmd!, [...args, "stop", "--config", configFile], {
        cwd: workDir,
        timeout: 30000,
      });
    } catch {
      // Ignore stop errors
    }
  }

  /**
   * Start Docker services
   */
  async dockerUp(config: TestConfig): Promise<void> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";
    console.log(`[${config.id}] Starting Docker services...`);

    const [cmd, ...args] = this.envioCli.split(" ");
    const result = await runCommand(
      cmd!,
      [...args, "local", "docker", "up", "--config", configFile],
      {
        cwd: workDir,
        timeout: 60000,
      }
    );

    if (result.exitCode !== 0) {
      throw new Error(`docker up failed: ${result.stderr}`);
    }

    // Wait for Hasura to be healthy
    const hasuraHealth = await waitForHasura(HASURA_PORT, 60);
    if (!hasuraHealth.success) {
      throw new Error(`Hasura health check failed: ${hasuraHealth.error}`);
    }
    console.log(
      `[${config.id}] Hasura healthy after ${hasuraHealth.attempts} attempts`
    );
  }

  /**
   * Run database migrations
   */
  async dbMigrate(config: TestConfig): Promise<void> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";
    console.log(`[${config.id}] Running DB migrations...`);

    const [cmd, ...args] = this.envioCli.split(" ");
    const result = await runCommand(
      cmd!,
      [...args, "local", "db-migrate", "up", "--config", configFile],
      {
        cwd: workDir,
        timeout: 60000,
      }
    );

    if (result.exitCode !== 0) {
      throw new Error(`db-migrate failed: ${result.stderr}`);
    }
  }

  /**
   * Start the indexer in dev mode
   */
  async startDev(config: TestConfig): Promise<IndexerContext> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";

    // Ensure port is free
    await killProcessOnPort(this.port);
    const portFree = await waitForPortFree(this.port, 10);
    if (!portFree) {
      throw new Error(`Port ${this.port} is not available`);
    }

    console.log(`[${config.id}] Starting indexer...`);

    const env: Record<string, string> = {
      TUI_OFF: "true",
      ...config.env,
    };

    this.currentProcess = startBackground(
      "pnpm",
      ["dev", "--config", configFile],
      {
        cwd: workDir,
        env,
      }
    );

    // Wait for indexer to be healthy
    const indexerHealth = await waitForIndexer(this.port, 120);
    if (!indexerHealth.success) {
      await this.cleanup();
      throw new Error(
        `Indexer health check failed after ${indexerHealth.attempts} attempts: ${indexerHealth.error}`
      );
    }
    console.log(
      `[${config.id}] Indexer healthy after ${indexerHealth.attempts} attempts (${indexerHealth.totalTimeMs}ms)`
    );

    return {
      workDir,
      port: this.port,
      cleanup: () => this.cleanup(),
    };
  }

  /**
   * Start the indexer using `pnpm start` (for exit tests)
   */
  async start(config: TestConfig): Promise<{ exitCode: number }> {
    const workDir = this.getWorkDir(config);
    const configFile = config.configFile ?? "config.yaml";

    console.log(`[${config.id}] Starting indexer (start mode)...`);

    const env: Record<string, string> = {
      TUI_OFF: "true",
      ...config.env,
    };

    const result = await runCommand(
      "pnpm",
      ["start", "--config", configFile],
      {
        cwd: workDir,
        env,
        timeout: config.timeout ?? 300000,
      }
    );

    return { exitCode: result.exitCode };
  }

  /**
   * Cleanup running processes
   */
  async cleanup(): Promise<void> {
    if (this.currentProcess) {
      try {
        this.currentProcess.kill("SIGTERM");
      } catch {
        // Process may have already exited
      }
      this.currentProcess = null;
    }

    await killProcessOnPort(this.port);
  }
}
