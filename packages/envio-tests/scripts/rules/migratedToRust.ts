// The runtime is moving from ReScript to Rust one directory at a time. Once a
// directory's logic lives in Rust, what stays in it is the ReScript that binds
// the Rust: a file there with no `external` binds nothing, so it is logic that
// came back.

import type { file, violation } from "./shared.ts";
import { blankComments, isRescript } from "./shared.ts";

export const migratedToRust: string[] = [];

export const findLogicInMigratedDirectories = (files: file[], directories = migratedToRust): violation[] =>
  files.flatMap((file) => {
    const directory = directories.find((directory) => file.path.startsWith(`${directory}/`));
    return directory === undefined || !isRescript(file) || /\bexternal\b/.test(blankComments(file.text))
      ? []
      : [
          {
            file: file.path,
            line: 1,
            title: "ReScript logic in a directory that moved to Rust",
            fix:
              "Write it in Rust under `packages/cli/src` and keep here only the file that binds it: " +
              `every \`.res\` file in \`${directory}\` declares the \`external\`s it binds.`,
          },
        ];
  });
