// The docs an agent acts on are read as true. A path one of them names stays
// in it after the file is renamed or deleted, and nothing else notices.

import type { file, violation } from "./shared.ts";

const isContributorDoc = (path: string) => path === "CLAUDE.md" || /^\.claude\/skills\/.+\/SKILL\.md$/.test(path);

const sourceExtension =
  /[\w-]\.(?:res|resi|rs|ts|mjs|js|json|jsonl|yaml|yml|toml|md|sh|graphql|hbs|snap)$/;

// A span is taken for a repo path when it is one word of path characters that
// has a directory or a source extension. A command, a placeholder
// (`<project>/.envio/`), a glob, a URL, an endpoint (`/metrics`) or a scoped
// package name is not one.
const pathNamedBy = (span: string): string | null => {
  const candidate = span.replace(/:\d+(?::\d+)?$/, "").replace(/^\.\//, "");
  if (!/^[\w.-][\w.\-/]*$/.test(candidate)) return null;
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
        if (/^\s*```/.test(line)) {
          inFence = !inFence;
          return [];
        }
        if (inFence) return [];
        return [...line.matchAll(/`([^`]+)`/g)].flatMap(([, span]) => {
          const named = pathNamedBy(span);
          return named === null || exists(named)
            ? []
            : [
                {
                  file: path,
                  line: index + 1,
                  title: `\`${span}\` is not a path in the repo`,
                  fix:
                    "Name where it lives now, or drop the sentence if it is gone. A path the build " +
                    "generates takes a placeholder, as in `<project>/.envio/types.d.ts`.",
                },
              ];
        });
      });
    });
};
