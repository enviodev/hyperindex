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
  const left = typeof a === "object" && a !== null ? (a as any).valueOf() : a;
  const right = typeof b === "object" && b !== null ? (b as any).valueOf() : b;

  const integral = (v: unknown) => typeof v === "bigint" || (typeof v === "number" && Number.isInteger(v));
  if (integral(left) && integral(right)) {
    // Only i64 / i64 stays 64-bit; anything narrower is an i32 in AssemblyScript
    // and must come back as a number, or the bigint spreads through every
    // arithmetic that follows.
    if (typeof left === "bigint" && typeof right === "bigint") {
      return left / right;
    }
    return Math.trunc(Number(left) / Number(right));
  }
  return (left as number) / (right as number);
}

export const DIVIDE_HELPER = "__envio_idiv";
export const RETAG_HELPER = "__envio_retag";

/** `changetype<Foo>(x)` → `__envio_retag(Foo, x)` when Foo is a class name. */
export function rewriteChangetype(source: string): string {
  if (!source.includes("changetype<")) return source;
  return source.replace(
    /changetype\s*<\s*([A-Za-z_][A-Za-z0-9_]*)\s*>\s*\(/g,
    `${RETAG_HELPER}($1, `,
  );
}

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

  const isSimpleTarget = (node: any): boolean =>
    node.kind === ts.SyntaxKind.Identifier ||
    (node.kind === ts.SyntaxKind.PropertyAccessExpression && isSimpleTarget(node.expression)) ||
    node.kind === ts.SyntaxKind.ThisKeyword;

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
    // `x /= y` divides too. Rewriting it needs the target twice, so it is only
    // safe when reading the target has no effect of its own — an identifier or
    // a dotted path. `a[i++] /= y` is left alone rather than evaluated twice.
    if (
      node.kind === ts.SyntaxKind.BinaryExpression &&
      node.operatorToken?.kind === ts.SyntaxKind.SlashEqualsToken &&
      isSimpleTarget(node.left)
    ) {
      const left = ts.skipTrivia(source, node.left.pos);
      const target = source.slice(left, node.left.end);
      const operator = ts.skipTrivia(source, node.operatorToken.pos);
      edits.push({
        at: operator,
        length: node.operatorToken.end - operator,
        text: `= ${DIVIDE_HELPER}(${target},`,
      });
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
