/**
 * Drives a command in a real pseudo-terminal and reads back what a terminal
 * emulator would show, so the TUI can be checked the way a person sees it.
 *
 * The PTY comes from util-linux `script`; its output is replayed through
 * xterm.js's headless emulator, the engine behind VS Code's terminal.
 */

import { spawn } from "child_process";
import xterm from "@xterm/headless";

export interface TerminalSize {
  cols: number;
  rows: number;
}

export interface PtyRun {
  /** Everything written to the terminal so far. */
  output(): Buffer;
  /** Types into the terminal, e.g. "\x03" for Ctrl-C. */
  type(keys: string): void;
  exited: Promise<number | null>;
  hasExited(): boolean;
  kill(): void;
}

const quote = (arg: string) => `'${arg.replaceAll("'", `'\\''`)}'`;

export function runInPty(
  command: string,
  args: string[],
  options: { cwd: string; env: Record<string, string>; size: TerminalSize },
): PtyRun {
  const { cols, rows } = options.size;
  const shell = `stty cols ${cols} rows ${rows}; exec ${[command, ...args].map(quote).join(" ")}`;
  const child = spawn("script", ["-qfec", shell, "/dev/null"], {
    cwd: options.cwd,
    env: options.env,
    stdio: ["pipe", "pipe", "inherit"],
  });
  const chunks: Buffer[] = [];
  child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
  let hasExited = false;
  const exited = new Promise<number | null>((resolve) =>
    child.on("close", (code) => {
      hasExited = true;
      resolve(code);
    }),
  );
  return {
    output: () => Buffer.concat(chunks),
    type: (keys) => child.stdin.write(keys),
    exited,
    hasExited: () => hasExited,
    // `script` outlives a hangup of its own; killing it closes the terminal,
    // which hangs up everything running in it.
    kill: () => child.kill("SIGKILL"),
  };
}

export interface Screen {
  /** Scrollback followed by the visible rows, trailing spaces trimmed. */
  lines: string[];
  cursorVisible: boolean;
  terminal: xterm.Terminal;
}

/** A row as it looks, trailing spaces trimmed. */
function rowText(line: xterm.IBufferLine): string {
  return line.translateToString(true);
}

export async function replay(
  output: Buffer,
  size: TerminalSize,
): Promise<Screen> {
  const terminal = new xterm.Terminal({
    ...size,
    scrollback: 10_000,
    allowProposedApi: true,
  });
  await new Promise<void>((resolve) => terminal.write(output, resolve));
  const buffer = terminal.buffer.active;
  const lines: string[] = [];
  for (let i = 0; i < buffer.length; i++) {
    const line = buffer.getLine(i);
    lines.push(line ? rowText(line) : "");
  }
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return {
    lines,
    cursorVisible:
      output.lastIndexOf("\x1b[?25h") >= output.lastIndexOf("\x1b[?25l"),
    terminal,
  };
}

export async function waitForScreen(
  run: PtyRun,
  size: TerminalSize,
  predicate: (screen: Screen) => boolean,
  timeoutMs: number,
): Promise<Screen> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const screen = await replay(run.output(), size);
    if (predicate(screen)) return screen;
    const reason = run.hasExited()
      ? "The command exited before the screen showed what was expected."
      : Date.now() > deadline
        ? `Timed out waiting for the screen after ${timeoutMs}ms.`
        : undefined;
    if (reason) {
      run.kill();
      throw new Error(
        `${reason} Last screen:\n${screen.lines.slice(-size.rows).join("\n")}`,
      );
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

const ansi16 = [
  "#000000",
  "#cd3131",
  "#0dbc79",
  "#e5e510",
  "#2472c8",
  "#bc3fbc",
  "#11a8cd",
  "#e5e5e5",
  "#666666",
  "#f14c4c",
  "#23d18b",
  "#f5f543",
  "#3b8eea",
  "#d670d6",
  "#29b8db",
  "#ffffff",
];

function paletteColor(index: number): string {
  if (index < 16) return ansi16[index]!;
  if (index >= 232) {
    const level = (8 + (index - 232) * 10).toString(16).padStart(2, "0");
    return `#${level}${level}${level}`;
  }
  const cube = index - 16;
  const level = (n: number) =>
    (n === 0 ? 0 : 55 + n * 40).toString(16).padStart(2, "0");
  return `#${level(Math.floor(cube / 36))}${level(Math.floor(cube / 6) % 6)}${level(cube % 6)}`;
}

const escapeXml = (text: string) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/** The visible screen as an SVG, for a person to look at in CI artifacts. */
export function toSvg(screen: Screen): string {
  const { terminal } = screen;
  const buffer = terminal.buffer.active;
  const cell = { width: 10, height: 20 };
  const parts: string[] = [];
  for (let row = 0; row < terminal.rows; row++) {
    const line = buffer.getLine(buffer.viewportY + row);
    if (!line) continue;
    const y = row * cell.height;
    for (let col = 0; col < terminal.cols; col++) {
      const c = line.getCell(col);
      if (!c || c.getWidth() === 0) continue;
      const x = col * cell.width;
      const width = cell.width * c.getWidth();
      const color = (rgb: boolean, palette: boolean, value: number) =>
        rgb
          ? `#${value.toString(16).padStart(6, "0")}`
          : palette
            ? paletteColor(value)
            : undefined;
      let fg = color(c.isFgRGB(), c.isFgPalette(), c.getFgColor()) ?? "#cccccc";
      let bg = color(c.isBgRGB(), c.isBgPalette(), c.getBgColor());
      if (c.isInverse()) [fg, bg] = [bg ?? "#1e1e1e", fg];
      if (bg) {
        parts.push(
          `<rect x="${x}" y="${y}" width="${width}" height="${cell.height}" fill="${bg}"/>`,
        );
      }
      const chars = c.getChars();
      const code = chars.codePointAt(0) ?? 0;
      if (code > 0x2800 && code <= 0x28ff) {
        // Braille and line glyphs as shapes, the way terminals that draw
        // them themselves show them.
        const dots = [
          [0x01, 0x08],
          [0x02, 0x10],
          [0x04, 0x20],
          [0x40, 0x80],
        ];
        dots.forEach((bits, dy) =>
          bits.forEach((bit, dx) => {
            if ((code - 0x2800) & bit) {
              parts.push(
                `<circle cx="${x + 3 + dx * 4}" cy="${y + 3 + dy * 4 + Math.floor(dy / 2)}" r="1.4" fill="${fg}"/>`,
              );
            }
          }),
        );
      } else if (chars === "━" || chars === "─") {
        const thickness = chars === "━" ? 4 : 2;
        parts.push(
          `<rect x="${x}" y="${y + (cell.height - thickness) / 2}" width="${width}" height="${thickness}" fill="${fg}"/>`,
        );
      } else if (chars && chars !== " ") {
        const weight = c.isBold() ? ` font-weight="bold"` : "";
        const underline = c.isUnderline() ? ` text-decoration="underline"` : "";
        parts.push(
          `<text x="${x}" y="${y + 15}" fill="${fg}"${weight}${underline}>${escapeXml(chars)}</text>`,
        );
      }
    }
  }
  const width = terminal.cols * cell.width;
  const height = terminal.rows * cell.height;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" font-family="ui-monospace, Menlo, Consolas, monospace" font-size="16" xml:space="preserve" shape-rendering="crispEdges">
<rect width="100%" height="100%" fill="#1e1e1e"/>
${parts.join("\n")}
</svg>
`;
}
