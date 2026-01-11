import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { PtySession, Keys } from "./pty-helper.js";

/**
 * Create a temporary directory for test projects
 */
export function createTempDir(prefix = "envio-test-"): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

/**
 * Clean up a temporary directory
 */
export function cleanupTempDir(dir: string): void {
  if (fs.existsSync(dir)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * Normalize terminal output for comparison
 * - Remove ANSI codes
 * - Normalize whitespace
 * - Remove cursor positioning sequences
 */
export function normalizeOutput(output: string): string {
  return output
    // Remove ANSI escape codes
    .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "")
    // Remove carriage returns
    .replace(/\r/g, "")
    // Normalize multiple newlines
    .replace(/\n{3,}/g, "\n\n")
    // Trim each line
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}

/**
 * Extract visible menu options from terminal output
 */
export function extractMenuOptions(output: string): string[] {
  const lines = normalizeOutput(output).split("\n");
  const options: string[] = [];

  for (const line of lines) {
    // Match lines that are menu options (have visible option text)
    // Skip lines that are prompts (end with ?) or help text
    const trimmed = line.trim();
    if (
      trimmed &&
      !trimmed.endsWith("?") &&
      !trimmed.startsWith("[") &&
      !trimmed.includes("↑/↓") &&
      !trimmed.includes("enter")
    ) {
      // Remove selection indicators
      const option = trimmed.replace(/^[▶❯>]\s*/, "").trim();
      if (option) {
        options.push(option);
      }
    }
  }

  return options;
}

/**
 * Flow step definition for declarative test writing
 */
export interface FlowStep {
  /** Wait for this text/prompt to appear */
  waitFor: string | RegExp;
  /** Action to take */
  action:
    | { type: "enter" }
    | { type: "type"; text: string }
    | { type: "select"; index: number }
    | { type: "selectByText"; text: string }
    | { type: "down"; count?: number }
    | { type: "up"; count?: number };
  /** Optional description for debugging */
  description?: string;
}

/**
 * Execute a flow of steps on a PTY session
 */
export async function executeFlow(
  session: PtySession,
  steps: FlowStep[]
): Promise<void> {
  for (const step of steps) {
    if (step.description) {
      console.log(`  Step: ${step.description}`);
    }

    await session.waitFor(step.waitFor);

    switch (step.action.type) {
      case "enter":
        await session.pressEnter();
        break;
      case "type":
        await session.type(step.action.text);
        await session.pressEnter();
        break;
      case "select":
        await session.selectOption(step.action.index);
        break;
      case "selectByText":
        // Find the option and select it
        const output = session.getOutput().clean;
        const lines = output.split("\n");
        let index = 0;
        let found = false;
        for (const line of lines) {
          if (line.includes(step.action.text)) {
            found = true;
            break;
          }
          if (line.match(/^[\s>▶❯]*[A-Za-z]/)) {
            index++;
          }
        }
        if (found) {
          for (let i = 0; i < index; i++) {
            await session.pressDown();
          }
        }
        await session.pressEnter();
        break;
      case "down":
        for (let i = 0; i < (step.action.count ?? 1); i++) {
          await session.pressDown();
        }
        break;
      case "up":
        for (let i = 0; i < (step.action.count ?? 1); i++) {
          await session.pressUp();
        }
        break;
    }
  }
}

/**
 * Snapshot of a prompt state for verification
 */
export interface PromptSnapshot {
  /** The prompt question text */
  prompt: string;
  /** Available options (for select prompts) */
  options?: string[];
  /** Default value if shown */
  defaultValue?: string;
  /** Help message if shown */
  helpMessage?: string;
}

/**
 * Capture the current prompt state from terminal output
 */
export function capturePromptSnapshot(output: string): PromptSnapshot {
  const clean = normalizeOutput(output);
  const lines = clean.split("\n").filter((l) => l.trim());

  // Find the prompt line (usually ends with ? or :)
  const promptLine = lines.find(
    (l) => l.includes("?") || (l.includes(":") && !l.includes("://"))
  );

  // Extract options (lines with selection indicators or option-like text)
  const options: string[] = [];
  let inOptions = false;

  for (const line of lines) {
    const trimmed = line.trim();

    // Start collecting after the prompt
    if (trimmed.includes("?")) {
      inOptions = true;
      continue;
    }

    if (inOptions && trimmed && !trimmed.startsWith("[")) {
      // Remove selection indicators and clean up
      const option = trimmed.replace(/^[▶❯>]\s*/, "").trim();
      if (option && !option.includes("↑") && !option.includes("↓")) {
        options.push(option);
      }
    }
  }

  return {
    prompt: promptLine ?? "",
    options: options.length > 0 ? options : undefined,
  };
}
