// The docs an agent acts on are read as true. A path one of them names stays
// in it after the file is renamed or deleted, and nothing else notices.

import type { file, violation } from "./shared.ts";

const isContributorDoc = (path: string) => path === "CLAUDE.md" || /^\.claude\/skills\/.+\/SKILL\.md$/.test(path);

const sourceExtension =
  /[\w-]\.(?:res|resi|rs|ts|mjs|js|json|jsonl|yaml|yml|toml|md|sh|graphql|hbs|snap)$/;

// A word is taken for a repo path when it is made of path characters and has a
// directory or a source extension. A placeholder (`<project>/.envio/`), a
// glob, a URL, an endpoint (`/metrics`), a scoped package name or a path out
// of the repo (`../elsewhere`) is not one.
const pathNamedBy = (word: string): string | null => {
  const candidate = word
    .replace(/^\(|[,;)]+$/g, "")
    .replace(/:\d+(?::\d+)?$/, "")
    .replace(/^\.\//, "")
    // A compiled module is named for its source, which is the tracked file.
    .replace(/(?<=\.res)\.m?js$/, "");
  if (!/^[\w.-][\w.\-/]*$/.test(candidate) || candidate.startsWith("..")) return null;
  return candidate.includes("/") || sourceExtension.test(candidate) ? candidate.replace(/\/$/, "") : null;
};

export const findMissingDocPaths = (files: file[]): violation[] => {
  const paths = files.map(({ path }) => path);
  // A doc names a file the way the sentence around it scopes it
  // (`src/commands.rs` under "Rust CLI: `packages/cli`"), so the tail of a
  // path counts, and so does a directory.
  const exists = (named: string) =>
    paths.some(
      (path) =>
        path === named ||
        path.startsWith(`${named}/`) ||
        path.endsWith(`/${named}`) ||
        path.includes(`/${named}/`),
    );
  return files
    .filter(({ path }) => isContributorDoc(path))
    .flatMap(({ path, text }) => {
      let inFence = false;
      return text.split("\n").flatMap((line, index) => {
        if (/^\s*(?:```|~~~)/.test(line)) {
          inFence = !inFence;
          return [];
        }
        // Most of the paths a skill names sit in its commands: every word of a
        // fenced line, and every word of a code span outside one.
        const code = inFence ? [line] : [...line.matchAll(/`([^`]+)`/g)].map(([, span]) => span);
        return code
          .flatMap((span) => span.trim().split(/\s+/))
          .flatMap((word) => {
            const named = pathNamedBy(word);
            return named === null || exists(named)
              ? []
              : [
                  {
                    file: path,
                    line: index + 1,
                    title: `\`${word}\` is not a path in the repo`,
                    fix:
                      "Name where it lives now, or drop the sentence if it is gone. A path the build " +
                      "generates takes a placeholder, as in `<project>/.envio/types.d.ts`, and a word that " +
                      "is no path at all loses its backticks.",
                  },
                ];
          });
      });
    });
};
