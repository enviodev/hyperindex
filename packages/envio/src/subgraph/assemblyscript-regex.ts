/**
 * `assemblyscript-regex`, the regular-expression library AssemblyScript
 * mappings import (Polymarket's resolution subgraph tests an update string with
 * it). The package is AssemblyScript through and through — `unchecked`, `<i32>`
 * casts, memory-level matching — so mappings get this JavaScript-backed class
 * with the same surface instead: a pattern, a `test`, an `exec` that answers a
 * match with its `index`, `input` and `matches` (the whole match, then each
 * group, an unmatched group as an empty string), and `replace`.
 */

const JsRegExp = globalThis.RegExp;

export class RegExpMatch {
  constructor(
    public index: number,
    public input: string,
    public matches: string[],
  ) {}
}

export class RegExp {
  lastIndex = 0;
  readonly source: string;
  readonly flags: string;
  private readonly re: globalThis.RegExp;

  constructor(pattern: string, flags = "") {
    this.source = pattern;
    this.flags = flags;
    this.re = new JsRegExp(pattern, flags);
  }

  get global(): boolean {
    return this.re.global;
  }
  get ignoreCase(): boolean {
    return this.re.ignoreCase;
  }
  get multiline(): boolean {
    return this.re.multiline;
  }

  test(text: string): boolean {
    return this.exec(text) !== null;
  }

  exec(text: string): RegExpMatch | null {
    const sticky = this.re.global || this.re.sticky;
    if (sticky) this.re.lastIndex = this.lastIndex;
    const match = this.re.exec(text);
    if (sticky) this.lastIndex = match ? this.re.lastIndex : 0;
    if (!match) return null;
    return new RegExpMatch(
      match.index,
      text,
      Array.from(match, (group) => group ?? ""),
    );
  }

  replace(text: string, replacement: string): string {
    return text.replace(this.re, replacement);
  }

  toString(): string {
    return `/${this.source}/${this.flags}`;
  }
}
