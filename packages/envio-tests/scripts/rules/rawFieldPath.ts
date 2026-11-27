import type { file, violation } from "./shared.ts";
import { blankComments, lineAtOffset, rescriptFilesOutsideTemplates } from "./shared.ts";

// Only a bare dotted path: a function or an expression inside %raw is
// JavaScript that has no binding to replace it.
const fieldPath = "[A-Za-z_$][\\w$]*(?:\\.[A-Za-z_$][\\w$]*)+";
const rawFieldPath = new RegExp(`%raw\\(\\s*(?:\`\\s*(${fieldPath})\\s*\`|"\\s*(${fieldPath})\\s*")\\s*\\)`, "g");

const checkedByTheCompiler = "the compiler checks a binding's name and type, and reads nothing inside %raw.";

export const findRawFieldPaths = (files: file[]): violation[] =>
  rescriptFilesOutsideTemplates(files).flatMap(({ path, text }) => {
    const code = blankComments(text);
    return [...code.matchAll(rawFieldPath)].map((match) => {
      const named = match[1] ?? match[2];
      const envVar = named.match(/^process\.env\.(\w+)$/)?.[1];
      return {
        file: path,
        line: lineAtOffset(code, match.index),
        title: `%raw reading ${named}`,
        fix: envVar
          ? `Read it with \`NodeJs.Process.process.env->Dict.get("${envVar}")\`: ${checkedByTheCompiler}`
          : `Bind it with \`@val external name: type = "${named}"\`: ${checkedByTheCompiler}`,
      };
    });
  });
