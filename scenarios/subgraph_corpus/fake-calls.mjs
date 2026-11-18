// Synthetic answers for an entry with no recorded fixture: every function in
// the project's ABIs, keyed by selector, answered with a valid encoding of its
// declared outputs. The values are made up (1, true, "FAKE", ...), so a pass
// says the mappings run against well-formed answers, not that they compute
// what graph-node would.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { subgraphKeccak256 } from "../../packages/envio/src/Core.res.mjs";

const word = (hex) => hex.padStart(64, "0");
const hexOf = (text) => Buffer.from(text).toString("hex");

const isDynamic = (param) => {
  const array = /^(.*)\[(\d*)\]$/.exec(param.type);
  if (array) return array[2] === "" || isDynamic({ ...param, type: array[1] });
  if (param.type === "tuple") return param.components.some(isDynamic);
  return param.type === "string" || param.type === "bytes";
};

// Non-zero wherever a mapping could divide by the value or treat zero as
// "missing": decimals, reserves and supplies are 1, addresses 0x…01.
function encodeOne(param) {
  const array = /^(.*)\[(\d*)\]$/.exec(param.type);
  if (array) {
    const length = array[2] === "" ? 1 : Number(array[2]);
    const items = encodeTuple(Array.from({ length }, () => ({ ...param, type: array[1] })));
    return array[2] === "" ? word("1") + items : items;
  }
  if (param.type === "tuple") return encodeTuple(param.components);
  if (param.type === "string" || param.type === "bytes") {
    const data = param.type === "string" ? hexOf("FAKE") : "01";
    return word((data.length / 2).toString(16)) + data.padEnd(64, "0");
  }
  if (param.type.startsWith("bytes")) return "01".padEnd(64, "0");
  return word("1");
}

function encodeTuple(params) {
  const heads = [];
  const tails = [];
  let offset = params.reduce((size, param) => size + (isDynamic(param) ? 32 : encodeOne(param).length / 2), 0);
  for (const param of params) {
    const encoded = encodeOne(param);
    if (isDynamic(param)) {
      heads.push(word(offset.toString(16)));
      tails.push(encoded);
      offset += encoded.length / 2;
    } else heads.push(encoded);
  }
  return heads.join("") + tails.join("");
}

const canonical = (param) => {
  const array = /^tuple(\[\d*\])*$/.exec(param.type);
  if (array) return `(${param.components.map(canonical).join(",")})${param.type.slice(5)}`;
  return param.type;
};

function abisIn(dir) {
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...abisIn(full));
    else if (entry.name.endsWith(".json")) {
      try {
        const parsed = JSON.parse(readFileSync(full, "utf8"));
        const abi = Array.isArray(parsed) ? parsed : parsed?.abi;
        if (Array.isArray(abi)) found.push(...abi.filter((item) => item?.type === "function"));
      } catch {}
    }
  }
  return found;
}

// A selector two ABIs declare with different outputs (ERC20's `symbol()` as
// `string` and as `bytes32`) gets the one with dynamic outputs: its encoding
// also decodes as the static one, the reverse doesn't.
export function fakeCallAnswers(projectDir) {
  const bySelector = new Map();
  for (const fn of abisIn(projectDir)) {
    const signature = `${fn.name}(${(fn.inputs ?? []).map(canonical).join(",")})`;
    const selector = Buffer.from(subgraphKeccak256(Buffer.from(signature))).toString("hex").slice(0, 8);
    const outputs = fn.outputs ?? [];
    const known = bySelector.get(selector);
    if (!known || (!known.some(isDynamic) && outputs.some(isDynamic))) bySelector.set(selector, outputs);
  }
  return (data) => {
    const outputs = bySelector.get(String(data).slice(2, 10).toLowerCase());
    return outputs === undefined ? undefined : `0x${encodeTuple(outputs)}`;
  };
}
