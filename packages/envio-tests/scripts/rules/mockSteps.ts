// A test that waits for the indexer to ask the source by counting event-loop
// ticks (`await Utils.delay(0)`) or polling the pending queries guesses at how
// many await hops production code takes. The guess is unwritable without trial
// and error and breaks the day production code gains an await. It is also
// unnecessary: `expectItemsQueries` waits for the queries it names, and a height
// answer with no call pending is held for the next one.

import type { file, violation } from "./shared.ts";
import { testRescriptFiles, withoutLineComment } from "./shared.ts";

const delay = /^\s*(?:await\s+)?Utils\.delay\(0\)\s*$/;
const mockStep =
  /^\s*(?:await\s+)?(?:let\s+\S+\s*=\s*)?\S*\b(expectItemsQueries|expectBlockHashLookup|expectHeightCalls|respondUpTo|drainPendingItemsQueries|pendingItemsQueries|resolveGetHeightOrThrow|resolveInitialHeight|enterReorgThreshold)\b/;
const pollStart = /\b(while\b|waitUntil\()/;

// The scan has to reach the next statement past whatever sits between it and
// the delay. A comment that hid a violation would make the lint quietly useless.
const nextCodeLine = (lines: string[], start: number): string | null => {
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

export const findGuessedWaits = (files: file[]): violation[] =>
  testRescriptFiles(files).flatMap(({ path, text }) => {
    const lines = text.split("\n");
    return lines.flatMap((line, index) => {
      const found: violation[] = [];
      const code = withoutLineComment(line);
      if (delay.test(code)) {
        const step = nextCodeLine(lines, index + 1)?.match(mockStep)?.[1];
        if (step) {
          found.push({
            file: path,
            line: index + 1,
            title: `Utils.delay(0) before ${step}`,
            fix:
              step === "resolveGetHeightOrThrow"
                ? "Delete the delay: a height answer with no call pending is held for the next call."
                : `Delete the delay: \`${step}\` waits for what it answers, or answers only what is already pending.`,
          });
        }
      }
      // A poll's condition sits on the same line or the one after it.
      if (pollStart.test(code)) {
        const condition = `${code} ${nextCodeLine(lines, index + 1) ?? ""}`;
        if (/\bpendingItemsQueries\b/.test(condition)) {
          found.push({
            file: path,
            line: index + 1,
            title: "Polling pendingItemsQueries",
            fix:
              "Replace the poll with `await mock.expectItemsQueries([...])` naming the queries " +
              "(`reply: LeavePending` for ones answered later).",
          });
        }
      }
      return found;
    });
  });
