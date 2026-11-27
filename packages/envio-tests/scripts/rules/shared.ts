// Paths are repo-relative with forward slashes, so they mean the same thing
// whether the lint runs from the package, from the root, or from CI — and so
// GitHub can attach an annotation to the line.
export type file = { path: string; text: string };

export type violation = { file: string; line: number; title: string; fix: string };

export const testRoot = "packages/envio-tests/test/";
export const runtimeRoot = "packages/envio/src/";

export const isRescript = ({ path }: file) => path.endsWith(".res");

export const testRescriptFiles = (files: file[]) =>
  files.filter((file) => file.path.startsWith(testRoot) && isRescript(file));

export const isTestHelper = (path: string) => path.startsWith(`${testRoot}helpers/`);

// The scaffolds under the CLI's templates are user projects: they have no
// `Utils` of ours to cast with, and a Handlebars file is not ReScript yet.
export const rescriptFilesOutsideTemplates = (files: file[]) =>
  files.filter((file) => isRescript(file) && !file.path.startsWith("packages/cli/templates/"));

// Every rule asks for the same files, so each is scanned once.
const blankedCommentsOnly = new Map<string, string>();
const blankedWithStrings = new Map<string, string>();

// ReScript source with its comments blanked, and its string contents too when
// asked. Blanked, not cut, so a line or an offset in the result is the same
// one in the file. It reads strings to know that a `//` or a `/*` inside one
// opens no comment, and comments nest. Code inside a template's `${...}` stays
// code.
export const blankComments = (text: string, { andStrings = false } = {}) => {
  const blanked = andStrings ? blankedWithStrings : blankedCommentsOnly;
  const known = blanked.get(text);
  if (known !== undefined) return known;
  const result = text.split("");
  const blank = (from: number, to: number) => {
    for (let at = from; at < to; at++) if (result[at] !== "\n") result[at] = " ";
  };
  let at = 0;
  const skipString = () => {
    const start = at++;
    while (at < text.length && text[at] !== '"') at += text[at] === "\\" ? 2 : 1;
    if (andStrings) blank(start + 1, at);
    at++;
  };
  const skipTemplate = () => {
    let literalStart = ++at;
    while (at < text.length && text[at] !== "`") {
      if (text[at] === "\\") {
        at += 2;
      } else if (text[at] === "$" && text[at + 1] === "{") {
        if (andStrings) blank(literalStart, at);
        at += 2;
        skipCode(true);
        literalStart = at;
      } else {
        at++;
      }
    }
    if (andStrings) blank(literalStart, at);
    at++;
  };
  const skipCode = (untilClosingBrace: boolean) => {
    let braces = 0;
    while (at < text.length) {
      const char = text[at];
      const next = text[at + 1];
      if (char === "/" && next === "/") {
        const end = text.indexOf("\n", at);
        blank(at, end === -1 ? text.length : end);
        at = end === -1 ? text.length : end;
      } else if (char === "/" && next === "*") {
        const start = at;
        let depth = 0;
        do {
          if (text.startsWith("/*", at)) depth++;
          else if (text.startsWith("*/", at)) depth--;
          at += text.startsWith("/*", at) || text.startsWith("*/", at) ? 2 : 1;
        } while (depth > 0 && at < text.length);
        blank(start, at);
      } else if (char === '"') {
        skipString();
      } else if (char === "`") {
        skipTemplate();
      } else if (char === "'" && /^'(?:\\.|[^\\'])'/.test(text.slice(at, at + 4))) {
        // A char literal, so `'"'` opens no string.
        at += text[at + 1] === "\\" ? 4 : 3;
      } else if (untilClosingBrace && char === "}" && braces === 0) {
        at++;
        return;
      } else {
        if (char === "{") braces++;
        if (char === "}") braces--;
        at++;
      }
    }
  };
  skipCode(false);
  const joined = result.join("");
  blanked.set(text, joined);
  return joined;
};

export const lineAtOffset = (text: string, offset: number) => text.slice(0, offset).split("\n").length;

// Work off the source clock (a handler or effect taking time, events from the
// addon's threads, throttled writes) still takes real time, and says so: a
// `// Real time:` comment covers the statement it sits on or above, the lines
// below it indented at least as deep, up to the next blank line.
const indentOf = (line: string) => line.length - line.trimStart().length;
export const isRealTimeAt = (lines: string[], index: number) => {
  for (let at = index; at >= 0 && lines[at].trim() !== ""; at--) {
    if (/\/\/\s*Real time:/.test(lines[at])) {
      const indent = indentOf(lines[at]);
      return lines.slice(at + 1, index + 1).every((line) => indentOf(line) >= indent);
    }
  }
  return false;
};
