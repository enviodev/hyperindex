import * as pty from "node-pty";
import * as path from "path";
import { fileURLToPath } from "url";
import stripAnsi from "strip-ansi";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Special keys for terminal interaction
 */
export const Keys = {
  ENTER: "\r",
  UP: "\x1b[A",
  DOWN: "\x1b[B",
  SPACE: " ",
  CTRL_C: "\x03",
  TAB: "\t",
} as const;

export interface PtyOptions {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
  timeout?: number;
}

export interface WaitForOptions {
  timeout?: number;
  stripAnsi?: boolean;
}

/**
 * Represents output from the terminal with utilities for inspection
 */
export class TerminalOutput {
  private chunks: string[] = [];

  append(data: string): void {
    this.chunks.push(data);
  }

  /**
   * Get raw output including ANSI codes
   */
  get raw(): string {
    return this.chunks.join("");
  }

  /**
   * Get clean output with ANSI codes stripped
   */
  get clean(): string {
    return stripAnsi(this.raw);
  }

  /**
   * Get output as lines (cleaned)
   */
  get lines(): string[] {
    return this.clean.split("\n").map((line) => line.trim());
  }

  /**
   * Get non-empty lines
   */
  get nonEmptyLines(): string[] {
    return this.lines.filter((line) => line.length > 0);
  }

  /**
   * Check if output contains a string
   */
  contains(text: string): boolean {
    return this.clean.includes(text);
  }

  /**
   * Clear collected output
   */
  clear(): void {
    this.chunks = [];
  }
}

/**
 * PTY session for interacting with CLI programs
 */
export class PtySession {
  private pty: pty.IPty | null = null;
  private output: TerminalOutput = new TerminalOutput();
  private exited = false;
  private exitCode: number | null = null;
  private defaultTimeout: number;

  constructor(private options: PtyOptions) {
    this.defaultTimeout = options.timeout ?? 10000;
  }

  /**
   * Start the PTY session
   */
  async start(): Promise<void> {
    const { command, args = [], cwd, env, cols = 120, rows = 30 } = this.options;

    this.pty = pty.spawn(command, args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd: cwd ?? process.cwd(),
      env: { ...process.env, ...env, TERM: "xterm-256color" },
    });

    this.pty.onData((data) => {
      this.output.append(data);
    });

    this.pty.onExit(({ exitCode }) => {
      this.exited = true;
      this.exitCode = exitCode;
    });

    // Give it a moment to start
    await this.sleep(100);
  }

  /**
   * Wait until output contains the specified text
   */
  async waitFor(
    text: string | RegExp,
    options?: WaitForOptions
  ): Promise<string> {
    const timeout = options?.timeout ?? this.defaultTimeout;
    const startTime = Date.now();
    const startOutput = this.output.clean;

    while (Date.now() - startTime < timeout) {
      const currentOutput = this.output.clean;
      const newOutput = currentOutput.slice(startOutput.length);

      const matches =
        typeof text === "string"
          ? currentOutput.includes(text)
          : text.test(currentOutput);

      if (matches) {
        return currentOutput;
      }

      if (this.exited) {
        throw new Error(
          `Process exited (code ${this.exitCode}) before finding: ${text}\nOutput:\n${currentOutput}`
        );
      }

      await this.sleep(50);
    }

    throw new Error(
      `Timeout waiting for: ${text}\nOutput:\n${this.output.clean}`
    );
  }

  /**
   * Wait for a selection prompt and return the visible options
   */
  async waitForSelect(prompt: string, options?: WaitForOptions): Promise<string[]> {
    const output = await this.waitFor(prompt, options);
    return this.parseSelectOptions(output);
  }

  /**
   * Parse select options from terminal output
   */
  private parseSelectOptions(output: string): string[] {
    const lines = output.split("\n");
    const options: string[] = [];

    for (const line of lines) {
      // Match lines that look like select options (with > or space prefix)
      // The inquire library uses > for selected and spaces for unselected
      const match = line.match(/^[\s>]*[▶❯>]?\s*(.+)$/);
      if (match && match[1].trim()) {
        const option = match[1].trim();
        // Skip if it looks like a prompt question
        if (!option.includes("?") && !option.startsWith("[")) {
          options.push(option);
        }
      }
    }

    return options;
  }

  /**
   * Send text to the terminal
   */
  write(text: string): void {
    if (!this.pty) {
      throw new Error("PTY not started");
    }
    this.pty.write(text);
  }

  /**
   * Send text and press Enter
   */
  async type(text: string): Promise<void> {
    this.write(text);
    await this.sleep(50);
  }

  /**
   * Press Enter
   */
  async pressEnter(): Promise<void> {
    this.write(Keys.ENTER);
    await this.sleep(100);
  }

  /**
   * Press arrow down
   */
  async pressDown(): Promise<void> {
    this.write(Keys.DOWN);
    await this.sleep(50);
  }

  /**
   * Press arrow up
   */
  async pressUp(): Promise<void> {
    this.write(Keys.UP);
    await this.sleep(50);
  }

  /**
   * Select option by moving down n times and pressing Enter
   */
  async selectOption(index: number): Promise<void> {
    for (let i = 0; i < index; i++) {
      await this.pressDown();
    }
    await this.pressEnter();
  }

  /**
   * Select option by its text (searches through options)
   */
  async selectByText(text: string, maxOptions = 20): Promise<void> {
    const output = this.output.clean;
    const lines = output.split("\n");

    // Find the option index
    let index = 0;
    for (const line of lines) {
      if (line.includes(text)) {
        break;
      }
      // Count lines that look like options
      if (line.match(/^[\s>]*[▶❯>]?\s*.+$/)) {
        index++;
      }
    }

    // Limit to maxOptions to prevent infinite loops
    index = Math.min(index, maxOptions);

    await this.selectOption(index);
  }

  /**
   * Get current output
   */
  getOutput(): TerminalOutput {
    return this.output;
  }

  /**
   * Clear captured output
   */
  clearOutput(): void {
    this.output.clear();
  }

  /**
   * Check if process has exited
   */
  hasExited(): boolean {
    return this.exited;
  }

  /**
   * Get exit code (null if still running)
   */
  getExitCode(): number | null {
    return this.exitCode;
  }

  /**
   * Kill the process
   */
  kill(): void {
    if (this.pty && !this.exited) {
      this.pty.kill();
    }
  }

  /**
   * Wait for process to exit
   */
  async waitForExit(timeout?: number): Promise<number> {
    const t = timeout ?? this.defaultTimeout;
    const startTime = Date.now();

    while (Date.now() - startTime < t) {
      if (this.exited) {
        return this.exitCode ?? -1;
      }
      await this.sleep(50);
    }

    throw new Error(`Timeout waiting for process to exit\nOutput:\n${this.output.clean}`);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

/**
 * Create and start a PTY session for the envio CLI
 */
export async function createEnvioSession(
  args: string[] = [],
  options: Partial<PtyOptions> = {}
): Promise<PtySession> {
  // Get the CLI directory - from e2e-tests/src (compiled to dist/), go up to cli
  const cliDir = path.resolve(__dirname, "../..");

  // Use cargo run to execute the CLI
  const session = new PtySession({
    command: "cargo",
    args: ["run", "--quiet", "--", ...args],
    cwd: options.cwd ?? cliDir,
    timeout: options.timeout ?? 15000,
    ...options,
  });

  await session.start();
  return session;
}
