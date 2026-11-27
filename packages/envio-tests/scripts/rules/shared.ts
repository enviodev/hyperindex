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

// `//` after a colon is a URL in a string, not a comment.
export const withoutLineComment = (line: string) => line.replace(/(?<!:)\/\/.*$/, "");

// Comments are blanked rather than cut, so an offset in the result is the same
// offset in the file.
export const blankComments = (text: string) =>
  text
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
    .replace(/(?<!:)\/\/.*$/gm, (comment) => " ".repeat(comment.length));

export const lineAtOffset = (text: string, offset: number) => text.slice(0, offset).split("\n").length;

// The scan has to reach the next statement past whatever sits between it and
// the line it started from. A comment that hid a violation would make the lint
// quietly useless.
export const nextCodeLine = (lines: string[], start: number): string | null => {
  let inBlockComment = false;
  for (let index = start; index < lines.length; index++) {
    let rest = lines[index];
    let code = "";
    if (inBlockComment) {
      const close = rest.indexOf("*/");
      if (close === -1) continue;
      rest = rest.slice(close + 2);
      inBlockComment = false;
    }
    for (;;) {
      const open = rest.indexOf("/*");
      if (open === -1) {
        code += rest;
        break;
      }
      const close = rest.indexOf("*/", open + 2);
      if (close === -1) {
        code += rest.slice(0, open);
        inBlockComment = true;
        break;
      }
      code += rest.slice(0, open);
      rest = rest.slice(close + 2);
    }
    const trimmed = code.trim();
    if (trimmed === "" || trimmed.startsWith("//")) continue;
    return code;
  }
  return null;
};

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
