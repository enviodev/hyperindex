// Shared schema describing the ClickHouse target table for an event.
//
// v1 hardcodes the ERC20 Transfer shape because that's our hackathon basecase.
// The columns chosen are everything that's free from a HyperSync log response —
// we get block, tx, and the indexed/non-indexed args without any extra round
// trips. Other event types are a follow-up.
//
// The column types are chosen so RowBinary on the wire is as compact as
// possible: the 32-byte tx hash and 20-byte addresses live as raw FixedString
// bytes (not "0x..." hex strings), which roughly halves the byte cost per row
// and avoids any string parsing on the CH side. `value` stays as String
// because uint256 fits a wide range and BigInt → 32-byte LE conversion in JS
// is meaningfully slower than emitting decimal text.

type t = {
  tableName: string,
  // Topic0 of the event (keccak256 of the signature). Used to filter HyperSync logs.
  topic0: string,
}

// keccak256("Transfer(address,address,uint256)") — well-known constant
let erc20TransferTopic0 = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let erc20Transfer: t = {
  tableName: "erc20_transfers",
  topic0: erc20TransferTopic0,
}

let createTableSqlForErc20Transfer = (~tableName) =>
  `CREATE TABLE IF NOT EXISTS \`${tableName}\` (
  chain_id        UInt32,
  block_number    UInt32,
  block_timestamp DateTime64(3, 'UTC'),
  log_index       UInt32,
  tx_hash         FixedString(32),
  contract        FixedString(20),
  \`from\`          FixedString(20),
  \`to\`            FixedString(20),
  value           String
)
ENGINE = MergeTree
ORDER BY (chain_id, block_number, log_index)
PARTITION BY toYYYYMM(block_timestamp)
SETTINGS index_granularity = 8192`
