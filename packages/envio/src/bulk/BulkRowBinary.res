// RowBinary encoder for the ERC20 Transfer schema.
//
// CH RowBinary is positional and untyped — every column is written as raw
// little-endian bytes in the order declared in CREATE TABLE. There's no
// per-row delimiter; the row count is implicit in the byte count and the
// column types. Done right, this is 3-5x faster than JSONCompactEachRow
// because there's no JSON serialization, no string parsing on the CH side,
// and the wire bytes are far smaller (binary tx_hash/address vs hex strings).
//
// Schema (must match BulkSchema.createTableSqlForErc20Transfer):
//   chain_id        UInt32                  4 bytes LE
//   block_number    UInt32                  4 bytes LE
//   block_timestamp DateTime64(3,'UTC')     8 bytes LE (Int64 ms since epoch)
//   log_index       UInt32                  4 bytes LE
//   tx_hash         FixedString(32)         32 raw bytes
//   contract        FixedString(20)         20 raw bytes
//   from            FixedString(20)         20 raw bytes
//   to              FixedString(20)         20 raw bytes
//   value           String                  varint(len) + utf8 bytes
//
// 92 bytes of fixed-width per row + the varint-prefixed `value` string.

type buffer

// Build a single Buffer containing the RowBinary encoding for an entire batch
// of decoded events. Hex strings (32-byte hash, 20-byte addresses) are decoded
// to their raw bytes once here, so the bytes hit the wire as binary.
//
// Inputs use parallel arrays. Hex inputs are accepted as either "0x..."-prefixed
// or unprefixed; the encoder slices the prefix when present. value strings are
// ASCII decimal and are written as-is (utf8 byte length === string length).
let encodeBatch: (
  ~chainIds: Uint32Array.t,
  ~blockNumbers: Uint32Array.t,
  ~blockTimestampsMs: Float64Array.t,
  ~logIndices: Uint32Array.t,
  ~txHashesHex: array<string>,
  ~contractsHex: array<string>,
  ~fromsHex: array<string>,
  ~tosHex: array<string>,
  ~valuesDec: array<string>,
  ~rowCount: int,
) => buffer = %raw(`function(chainIds, blockNumbers, blockTimestampsMs, logIndices,
                                  txHashesHex, contractsHex, fromsHex, tosHex,
                                  valuesDec, rowCount) {
  const n = rowCount;

  // Hex inputs may carry "0x"; we slice it off before Buffer.write(..., "hex").
  // Detect once with charCode to avoid a string-equality check per row.
  function hexBody(s) {
    return (s.length >= 2 && s.charCodeAt(0) === 48 && (s.charCodeAt(1) === 120 || s.charCodeAt(1) === 88))
      ? s.slice(2) : s;
  }

  // Pre-compute total size. Fixed portion = 4+4+8+4+32+20+20+20 = 112 bytes
  // per row. Variable portion is the value String — varint length prefix
  // (1 byte for len < 128, 2 for len < 16384) plus the ASCII bytes.
  const FIXED = 112;
  let total = FIXED * n;
  // value strings are ASCII decimals — string length === byte length.
  for (let i = 0; i < n; i++) {
    const v = valuesDec[i];
    if (typeof v !== "string") {
      throw new Error("BulkRowBinary.encodeBatch: valuesDec[" + i + "] is " + (v === undefined ? "undefined" : typeof v) + " (rowCount=" + n + ")");
    }
    const len = v.length;
    total += len + (len < 128 ? 1 : len < 16384 ? 2 : 3);
  }

  const buf = Buffer.allocUnsafe(total);
  let off = 0;

  for (let i = 0; i < n; i++) {
    // chain_id, block_number — UInt32 LE
    buf.writeUInt32LE(chainIds[i], off);     off += 4;
    buf.writeUInt32LE(blockNumbers[i], off); off += 4;
    // block_timestamp DateTime64(3) — Int64 LE milliseconds. JS numbers cover
    // ms-precision timestamps until year 285k, so the high 32 bits are
    // representable exactly as Math.floor(ms/2^32).
    const ms = blockTimestampsMs[i];
    const high = Math.floor(ms / 4294967296);
    const low  = ms - high * 4294967296;
    buf.writeUInt32LE(low, off); off += 4;
    buf.writeInt32LE(high, off); off += 4;
    // log_index — UInt32 LE
    buf.writeUInt32LE(logIndices[i], off); off += 4;
    // tx_hash — FixedString(32). 64 hex chars expected.
    buf.write(hexBody(txHashesHex[i]), off, 32, "hex");  off += 32;
    // contract, from, to — FixedString(20). 40 hex chars expected.
    buf.write(hexBody(contractsHex[i]), off, 20, "hex"); off += 20;
    buf.write(hexBody(fromsHex[i]),     off, 20, "hex"); off += 20;
    buf.write(hexBody(tosHex[i]),       off, 20, "hex"); off += 20;
    // value — String (varint length + utf8 bytes, all ASCII)
    const v = valuesDec[i];
    const vLen = v.length;
    if (vLen < 128) {
      buf[off++] = vLen;
    } else if (vLen < 16384) {
      buf[off++] = (vLen & 0x7f) | 0x80;
      buf[off++] = vLen >> 7;
    } else {
      buf[off++] = (vLen & 0x7f) | 0x80;
      buf[off++] = ((vLen >> 7) & 0x7f) | 0x80;
      buf[off++] = vLen >> 14;
    }
    buf.write(v, off, vLen, "utf8");
    off += vLen;
  }

  return buf;
}`)

// @clickhouse/client v1.17 explicitly rejects RowBinary in its `insert()`
// API (RowBinary is not in their `SupportedRawFormats` list), so we POST
// the raw bytes directly to the HTTP endpoint instead. The endpoint is the
// same protocol that `@clickhouse/client` uses under the hood — we just
// skip the JS-side validator that's blocking us.
//
// URL form: ${host}/?query=INSERT+INTO+${db}.${table}+FORMAT+RowBinary
// Body:     raw bytes (Content-Type: application/octet-stream)
// Auth:     Basic ${b64(user:pass)} when credentials supplied
let insertRowBinary: (
  ~url: string,
  ~database: string,
  ~table: string,
  ~username: string,
  ~password: string,
  ~body: buffer,
) => promise<unit> = %raw(`async function(url, database, table, username, password, body) {
  const q = "INSERT INTO " + database + ".\`" + table + "\` FORMAT RowBinary";
  const target = url.replace(/\/+$/, "") + "/?" + new URLSearchParams({ query: q }).toString();
  const headers = { "Content-Type": "application/octet-stream" };
  if (username || password) {
    headers["Authorization"] = "Basic " +
      Buffer.from(username + ":" + password, "utf8").toString("base64");
  }
  const res = await fetch(target, {
    method: "POST",
    headers,
    body,
    // Node's fetch (undici) handles keep-alive automatically.
  });
  if (!res.ok) {
    const text = await res.text();
    const e = new Error("ClickHouse RowBinary insert failed: " + res.status + " " + text);
    e.status = res.status;
    throw e;
  }
}`)
