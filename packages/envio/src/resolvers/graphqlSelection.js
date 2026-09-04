// Recovers a resolver's selection tree from the operation text Hasura sends.
//
// Hasura hands an action handler `request_query`, the raw GraphQL document,
// and nothing else about what the caller asked for -- there is no parsed
// selection in the payload. A resolver that skips expensive work when a field
// is not requested therefore needs the document read back, which is what this
// does: names and nesting, aliases resolved to the declared name, fragments
// inlined, which is the same shape envio-serve resolves against the output
// type.
//
// The selection is an optimisation and never correctness -- a resolver that
// ignores it is still right, only slower. So every failure here answers with an
// empty tree, which means "assume everything was asked for", and no request is
// ever refused because its query could not be read.

// A document this size is not a client query. Bailing keeps a pathological
// body from being lexed token by token before the request is answered.
const MAX_QUERY_BYTES = 128 * 1024;

const NAME_START = /[_A-Za-z]/;
const NAME_CHAR = /[_0-9A-Za-z]/;
const DIGIT = /[0-9]/;

const PUNCTUATORS = new Set(["!", "$", "&", "(", ")", ":", "=", "@", "[", "]", "{", "|", "}"]);

// Lexed, so a brace inside a string argument is a character and not structure.
function lex(source) {
  const tokens = [];
  let i = 0;
  const length = source.length;

  while (i < length) {
    const char = source[i];

    if (char === "﻿" || char === " " || char === "\t" || char === "\n" || char === "\r" || char === ",") {
      i += 1;
      continue;
    }

    if (char === "#") {
      while (i < length && source[i] !== "\n" && source[i] !== "\r") i += 1;
      continue;
    }

    if (char === "." && source.startsWith("...", i)) {
      tokens.push({ kind: "...", value: "..." });
      i += 3;
      continue;
    }

    if (PUNCTUATORS.has(char)) {
      tokens.push({ kind: char, value: char });
      i += 1;
      continue;
    }

    if (NAME_START.test(char)) {
      let end = i + 1;
      while (end < length && NAME_CHAR.test(source[end])) end += 1;
      tokens.push({ kind: "name", value: source.slice(i, end) });
      i = end;
      continue;
    }

    if (char === '"') {
      if (source.startsWith('"""', i)) {
        let end = i + 3;
        while (end < length) {
          if (source[end] === "\\" && source.startsWith('\\"""', end)) {
            end += 4;
            continue;
          }
          if (source.startsWith('"""', end)) break;
          end += 1;
        }
        if (end >= length) throw new Error("Unterminated block string");
        tokens.push({ kind: "value", value: source.slice(i, end + 3) });
        i = end + 3;
        continue;
      }
      let end = i + 1;
      while (end < length && source[end] !== '"') {
        end += source[end] === "\\" ? 2 : 1;
      }
      if (end >= length) throw new Error("Unterminated string");
      tokens.push({ kind: "value", value: source.slice(i, end + 1) });
      i = end + 1;
      continue;
    }

    if (DIGIT.test(char) || (char === "-" && DIGIT.test(source[i + 1] ?? ""))) {
      let end = i + 1;
      while (end < length && /[0-9eE.+-]/.test(source[end])) end += 1;
      tokens.push({ kind: "value", value: source.slice(i, end) });
      i = end;
      continue;
    }

    throw new Error(`Unexpected character '${char}'`);
  }

  return tokens;
}

const OPERATIONS = new Set(["query", "mutation", "subscription"]);

class Parser {
  constructor(tokens) {
    this.tokens = tokens;
    this.at = 0;
    this.fragments = new Map();
    this.operations = [];
  }

  peek(offset = 0) {
    return this.tokens[this.at + offset];
  }

  next() {
    const token = this.tokens[this.at];
    if (token === undefined) throw new Error("Unexpected end of document");
    this.at += 1;
    return token;
  }

  expect(kind) {
    const token = this.next();
    if (token.kind !== kind) throw new Error(`Expected ${kind}, found ${token.kind}`);
    return token;
  }

  parseDocument() {
    while (this.at < this.tokens.length) {
      const token = this.peek();
      if (token.kind === "{") {
        this.operations.push(this.parseSelectionSet());
      } else if (token.kind === "name" && OPERATIONS.has(token.value)) {
        this.next();
        if (this.peek()?.kind === "name") this.next();
        this.skipParens();
        this.skipDirectives();
        this.operations.push(this.parseSelectionSet());
      } else if (token.kind === "name" && token.value === "fragment") {
        this.next();
        const name = this.expect("name").value;
        this.expect("name"); // `on`
        this.parseTypeCondition();
        this.skipDirectives();
        this.fragments.set(name, this.parseSelectionSet());
      } else {
        throw new Error(`Unexpected ${token.kind} at top level`);
      }
    }
    return this;
  }

  // A type condition is a single name, but `[T!]!`-shaped tokens appear in
  // variable definitions handled by skipParens, so only the name form is here.
  parseTypeCondition() {
    this.expect("name");
  }

  skipParens() {
    if (this.peek()?.kind !== "(") return;
    let depth = 0;
    do {
      const token = this.next();
      if (token.kind === "(") depth += 1;
      else if (token.kind === ")") depth -= 1;
      else if (token.kind === "{") depth += 1;
      else if (token.kind === "}") depth -= 1;
    } while (depth > 0);
  }

  skipDirectives() {
    while (this.peek()?.kind === "@") {
      this.next();
      this.expect("name");
      this.skipParens();
    }
  }

  parseSelectionSet() {
    this.expect("{");
    const selections = [];
    while (this.peek()?.kind !== "}") {
      selections.push(this.parseSelection());
    }
    this.expect("}");
    return selections;
  }

  parseSelection() {
    if (this.peek().kind === "...") {
      this.next();
      const token = this.peek();
      if (token?.kind === "name" && token.value !== "on") {
        this.next();
        this.skipDirectives();
        return { kind: "spread", name: token.value };
      }
      if (token?.kind === "name") {
        this.next();
        this.parseTypeCondition();
      }
      this.skipDirectives();
      return { kind: "inline", selections: this.parseSelectionSet() };
    }

    let name = this.expect("name").value;
    if (this.peek()?.kind === ":") {
      // An alias renames the field for the caller; the resolver only knows the
      // name it declared, so the alias is dropped rather than reported.
      this.next();
      name = this.expect("name").value;
    }
    this.skipParens();
    this.skipDirectives();
    const selections = this.peek()?.kind === "{" ? this.parseSelectionSet() : null;
    return { kind: "field", name, selections };
  }
}

function collectFields(selections, fragments, seenFragments, into) {
  for (const selection of selections) {
    if (selection.kind === "field") {
      if (selection.name === "__typename") continue;
      const existing = into[selection.name] ?? {};
      into[selection.name] = existing;
      if (selection.selections !== null) {
        collectFields(selection.selections, fragments, seenFragments, existing);
      }
    } else if (selection.kind === "inline") {
      collectFields(selection.selections, fragments, seenFragments, into);
    } else if (!seenFragments.has(selection.name)) {
      const fragment = fragments.get(selection.name);
      if (fragment !== undefined) {
        seenFragments.add(selection.name);
        collectFields(fragment, fragments, seenFragments, into);
        seenFragments.delete(selection.name);
      }
    }
  }
  return into;
}

function findField(selections, fragments, fieldName, seenFragments, into) {
  for (const selection of selections) {
    if (selection.kind === "field") {
      if (selection.name === fieldName && selection.selections !== null) {
        collectFields(selection.selections, fragments, new Set(), into);
      } else if (selection.selections !== null) {
        findField(selection.selections, fragments, fieldName, seenFragments, into);
      }
    } else if (selection.kind === "inline") {
      findField(selection.selections, fragments, fieldName, seenFragments, into);
    } else if (!seenFragments.has(selection.name)) {
      const fragment = fragments.get(selection.name);
      if (fragment !== undefined) {
        seenFragments.add(selection.name);
        findField(fragment, fragments, fieldName, seenFragments, into);
        seenFragments.delete(selection.name);
      }
    }
  }
  return into;
}

/**
 * The selection tree for `fieldName`, as names and nesting.
 *
 * Hasura sends no operation name, so a document with more than one operation
 * cannot be narrowed to the one that ran. Every field of that name is merged
 * instead: a superset means a resolver does work it could have skipped, where
 * a subset would have it skip work that was asked for.
 */
export function selectionFromRequestQuery(requestQuery, fieldName) {
  if (typeof requestQuery !== "string" || requestQuery.length === 0) return {};
  if (requestQuery.length > MAX_QUERY_BYTES) return {};
  try {
    const document = new Parser(lex(requestQuery)).parseDocument();
    return findField(
      document.operations.flat(),
      document.fragments,
      fieldName,
      new Set(),
      {}
    );
  } catch {
    return {};
  }
}
