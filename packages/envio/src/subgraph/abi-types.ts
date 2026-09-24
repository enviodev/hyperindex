/**
 * Contract-call signatures and ABI type lists as graph codegen writes them.
 * Free of envio imports: the graph-ts shim reads them too.
 */

export type ParsedSignature = {
  name: string;
  inputs: string;
  outputs: string;
};

/**
 * graph codegen emits `"balanceOf(address):(uint256)"`. Types only, no names —
 * which is all `parseAbiParameters` needs.
 */
export function parseSignature(signature: string): ParsedSignature {
  const open = signature.indexOf("(");
  if (open === -1) {
    throw new Error(`Unreadable contract call signature "${signature}"`);
  }
  const name = signature.slice(0, open);

  let depth = 0;
  let close = -1;
  for (let index = open; index < signature.length; index++) {
    const char = signature[index];
    if (char === "(") depth++;
    if (char === ")") {
      depth--;
      if (depth === 0) {
        close = index;
        break;
      }
    }
  }
  if (close === -1) {
    throw new Error(`Unreadable contract call signature "${signature}"`);
  }

  const inputs = signature.slice(open + 1, close);
  const rest = signature.slice(close + 1).replace(/^:/, "");
  const outputs = rest.startsWith("(") ? rest.slice(1, -1) : rest;

  return { name, inputs, outputs };
}

/** `address,(uint256,bytes)` → `["address", "(uint256,bytes)"]`. */
export function splitTypes(list: string): string[] {
  const types: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < list.length; index++) {
    const char = list[index];
    if (char === "(") depth++;
    else if (char === ")") depth--;
    else if (char === "," && depth === 0) {
      types.push(list.slice(start, index));
      start = index + 1;
    }
  }
  if (list.length > 0) types.push(list.slice(start));
  return types;
}
