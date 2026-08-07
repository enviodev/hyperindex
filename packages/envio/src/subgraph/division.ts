/**
 * AssemblyScript divides two integers as integers. JavaScript doesn't.
 *
 * `let dayID = timestamp / 86400` is an i32 division in a mapping and a float
 * division here, and the difference travels: Uniswap multiplies the bucket back
 * out and writes it to an `Int` column, where `1588712972.0000002` is a type
 * error rather than a wrong number — but an entity id built the same way would
 * simply be wrong. Nothing in the shim can intercept `/` between two plain
 * numbers, so the operator is rewritten as the mapping is loaded.
 *
 * The rewrite is textual, driven by the TypeScript parser every subgraph project
 * already has: each `a / b` becomes `__envio_idiv(a, b)`, which truncates only
 * when both operands really are integers and otherwise divides as before — an
 * `f64` in AssemblyScript divides as a float too.
 */

import { createRequire } from "node:module";
import path from "node:path";

type Edit = { at: number; length: number; text: string };

let typescript: any | null | undefined;

/**
 * The project's own TypeScript, which `graph-cli` puts there. Resolving from the
 * project rather than from here keeps the shim free of a parser dependency.
 */
export function loadTypeScript(root: string): any | null {
  if (typescript !== undefined) return typescript;
  try {
    const require = createRequire(path.join(path.resolve(root), "package.json"));
    typescript = require("typescript");
  } catch {
    typescript = null;
  }
  return typescript;
}

export function integerDivision(a: unknown, b: unknown): unknown {
  if (
    typeof a === "number" &&
    typeof b === "number" &&
    Number.isInteger(a) &&
    Number.isInteger(b)
  ) {
    return Math.trunc(a / b);
  }
  return (a as number) / (b as number);
}

export const DIVIDE_HELPER = "__envio_idiv";

/** Returns the source unchanged when it divides nothing, or can't be parsed. */
export function rewriteDivision(source: string): string {
  if (!source.includes("/")) return source;
  const ts = typescript;
  if (!ts) return source;

  let file: any;
  try {
    file = ts.createSourceFile("mapping.ts", source, ts.ScriptTarget.Latest, false, ts.ScriptKind.TS);
  } catch {
    return source;
  }

  const edits: Edit[] = [];
  const visit = (node: any) => {
    if (
      node.kind === ts.SyntaxKind.BinaryExpression &&
      node.operatorToken?.kind === ts.SyntaxKind.SlashToken
    ) {
      const left = ts.skipTrivia(source, node.left.pos);
      const operator = ts.skipTrivia(source, node.operatorToken.pos);
      edits.push({ at: left, length: 0, text: `${DIVIDE_HELPER}(` });
      edits.push({ at: operator, length: node.operatorToken.end - operator, text: "," });
      edits.push({ at: node.right.end, length: 0, text: ")" });
    }
    ts.forEachChild(node, visit);
  };
  try {
    ts.forEachChild(file, visit);
  } catch {
    return source;
  }
  if (edits.length === 0) return source;

  // Applied back to front so an outer division's insertion points stay valid
  // while an inner one is rewritten.
  edits.sort((a, b) => b.at - a.at || b.length - a.length);
  let out = source;
  for (const edit of edits) {
    out = out.slice(0, edit.at) + edit.text + out.slice(edit.at + edit.length);
  }
  return out;
}
