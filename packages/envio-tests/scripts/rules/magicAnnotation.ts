import type { file, violation } from "./shared.ts";
import { blankComments, isRescript, lineAtOffset } from "./shared.ts";

// The scaffolds under the CLI's templates are user projects: they have no
// `Utils` of ours to cast with, and a Handlebars file is not ReScript yet.
const templates = "packages/cli/templates/";

// The formatter breaks a long annotation over lines, so the paren and the
// colon can each sit a line away from the name.
const bareMagic = /(?<!\(\s*)\bUtils\.magic\b|\bUtils\.magic\b(?!\s*:)/g;

export const findUnannotatedMagic = (files: file[]): violation[] =>
  files
    .filter((file) => isRescript(file) && !file.path.startsWith(templates))
    .flatMap(({ path, text }) => {
      const code = blankComments(text);
      return [...code.matchAll(bareMagic)].map((match) => ({
        file: path,
        line: lineAtOffset(code, match.index),
        title: "Utils.magic without its types",
        fix:
          "Write both ends: `value->(Utils.magic: inputType => outputType)`. A bare cast takes whatever " +
          "types inference hands it, so a change upstream changes what it casts and nothing fails.",
      }));
    });
