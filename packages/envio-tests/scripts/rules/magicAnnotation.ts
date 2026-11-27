import type { file, violation } from "./shared.ts";
import { blankComments, lineAtOffset, rescriptFilesOutsideTemplates } from "./shared.ts";

const bareMagic = /\bUtils\.magic\b(?!:)/g;

export const findUnannotatedMagic = (files: file[]): violation[] =>
  rescriptFilesOutsideTemplates(files).flatMap(({ path, text }) => {
    const code = blankComments(text, { andStrings: true });
    return [...code.matchAll(bareMagic)].map((match) => ({
      file: path,
      line: lineAtOffset(code, match.index),
      title: "Utils.magic without its types",
      fix:
        "Write both ends: `value->(Utils.magic: inputType => outputType)`. A bare cast takes whatever " +
        "types inference hands it, so a change upstream changes what it casts and nothing fails.",
    }));
  });
