// A test that waits for the indexer to ask the source by counting event-loop
// ticks (`await Utils.delay(0)`) or polling the pending queries guesses at how
// many await hops production code takes. The guess is unwritable without trial
// and error and breaks the day production code gains an await. It is also
// unnecessary: `expectItemsQueries` waits for the queries it names, and a height
// answer with no call pending is held for the next one.

import type { file, violation } from "./shared.ts";
import { blankComments, testRescriptFiles } from "./shared.ts";

const delay = /^\s*(?:await\s+)?Utils\.delay\(0\)\s*$/;
const mockStep =
  /^\s*(?:await\s+)?(?:let\s+\S+\s*=\s*)?\S*\b(expectItemsQueries|expectBlockHashLookup|expectHeightCalls|respondUpTo|drainPendingItemsQueries|pendingItemsQueries|resolveGetHeightOrThrow|resolveInitialHeight|enterReorgThreshold)\b/;
const pollStart = /\b(while\b|waitUntil\()/;

export const findGuessedWaits = (files: file[]): violation[] =>
  testRescriptFiles(files).flatMap(({ path, text }) => {
    const lines = blankComments(text).split("\n");
    // Blank lines and comments between two statements hide nothing: a comment
    // that hid a violation would make the lint quietly useless.
    const nextCodeLine = (after: number) => lines.slice(after + 1).find((line) => line.trim() !== "") ?? "";
    return lines.flatMap((code, index) => {
      const found: violation[] = [];
      if (delay.test(code)) {
        const step = nextCodeLine(index).match(mockStep)?.[1];
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
        const condition = `${code} ${nextCodeLine(index)}`;
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
