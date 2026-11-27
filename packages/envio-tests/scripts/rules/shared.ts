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

// `//` after a colon is a URL in a string, not a comment.
export const withoutLineComment = (line: string) => line.replace(/(?<!:)\/\/.*$/, "");

// Comments are blanked rather than cut, so an offset in the result is the same
// offset in the file.
export const blankComments = (text: string) =>
  text
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
    .replace(/(?<!:)\/\/.*$/gm, (comment) => " ".repeat(comment.length));

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
