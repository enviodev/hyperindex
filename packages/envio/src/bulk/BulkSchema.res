// Shared schema describing the ClickHouse target table for an event.
//
// v1 hardcodes the ERC20 Transfer shape because that's our hackathon basecase.
// The columns chosen are everything that's free from a HyperSync log response —
// we get block, tx, and the indexed/non-indexed args without any extra round
// trips. Other event types are a follow-up.

type t = {
  tableName: string,
  // Topic0 of the event (keccak256 of the signature). Used to filter HyperSync logs.
  topic0: string,
  // Number of bytes the encoded row occupies on average (used for chunk sizing).
  approxRowBytes: int,
}

// keccak256("Transfer(address,address,uint256)") — well-known constant
let erc20TransferTopic0 = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let erc20Transfer: t = {
  tableName: "erc20_transfers",
  topic0: erc20TransferTopic0,
  approxRowBytes: 220,
}

let createTableSqlForErc20Transfer = (~tableName) =>
  `CREATE TABLE IF NOT EXISTS \`${tableName}\` (
  chain_id        UInt32,
  block_number    UInt32,
  block_timestamp DateTime64(3, 'UTC'),
  log_index       UInt32,
  tx_hash         String,
  contract        String,
  \`from\`          String,
  \`to\`            String,
  value           String,
  INDEX idx_from \`from\`    TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_to   \`to\`      TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_tx   tx_hash   TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = ReplacingMergeTree
ORDER BY (chain_id, block_number, log_index)
PARTITION BY toYYYYMM(block_timestamp)
SETTINGS index_granularity = 8192`

// JSONCompactEachRow column order — must match the CREATE TABLE column order
// because the format is positional, not named. If you change the schema, update
// both this list and the encode function in BulkWorker together.
let columnsErc20Transfer = [
  "chain_id",
  "block_number",
  "block_timestamp",
  "log_index",
  "tx_hash",
  "contract",
  "from",
  "to",
  "value",
]
