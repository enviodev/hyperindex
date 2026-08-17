/**
 * How a corpus case becomes a vitest test. Every suite that runs the corpus
 * shares this, so a case is judged the same way wherever it runs.
 */

import type { CorpusCase } from "./corpus.js";

type ItFn = {
  (name: string, fn: () => Promise<void>, timeout?: number): void;
  fails: (name: string, fn: () => Promise<void>, timeout?: number) => void;
  skip: (name: string, fn: () => Promise<void>, timeout?: number) => void;
};

/**
 * `recordOnly` cases exist to capture Hasura's answer, not to hold serve to
 * it. `knownGap` cases run as expected failures, so vitest fails them if they
 * start passing and the annotation cannot outlive the difference.
 */
export function itForCase(it: ItFn, corpusCase: CorpusCase) {
  if (corpusCase.recordOnly) return it.skip;
  if (corpusCase.knownGap) return it.fails;
  return it;
}

export function caseTitle(corpusCase: CorpusCase): string {
  return corpusCase.knownGap
    ? `${corpusCase.name} [known gap: ${corpusCase.knownGap}]`
    : corpusCase.name;
}
