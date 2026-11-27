//! EVM tables: logs, transactions and blocks, what fills them from a source's
//! rows, and how their cells read back as the fields handlers select.

use alloy_primitives::U256;
use anyhow::{Context, Result};
use hypersync_client::format;
use hypersync_client::simple_types;
use strum::VariantArray;

use super::table::{make_key, ChunkBuilder, ColumnKind, RowRef, Schema, MAX_POSITION};
use crate::chain_buffer::deliver::{build_columns, cells, hex_quantity, Column, Columns};
use crate::ecosystems::evm::fields::{EvmBlockField, EvmTxField};
use crate::ecosystems::evm::format::{
    encode_address, map_i64, AccessList as AccessListItem, Authorization as AuthorizationItem,
};

pub(crate) mod log_column {
    pub(crate) const TRANSACTION_INDEX: usize = 0;
    pub(crate) const ADDRESS: usize = 1;
    pub(crate) const TOPIC0: usize = 2;
    pub(crate) const DATA: usize = 6;
}

pub(crate) fn logs_schema() -> Schema {
    Schema {
        columns: vec![
            ColumnKind::U32,
            ColumnKind::Fixed(20),
            ColumnKind::Fixed(32),
            ColumnKind::Fixed(32),
            ColumnKind::Fixed(32),
            ColumnKind::Fixed(32),
            ColumnKind::Var,
        ],
        has_tiebreak: false,
        has_fetched: false,
    }
}

/// A log row's fields as matching reads them.
pub(crate) struct LogView<'a> {
    pub(crate) block_number: u64,
    pub(crate) address: &'a [u8],
    pub(crate) topics: [Option<&'a [u8]>; 4],
}

impl<'a> LogView<'a> {
    pub(crate) fn of_row(row: &RowRef<'a>) -> Option<LogView<'a>> {
        let row = *row;
        Some(LogView {
            block_number: row.block_number(),
            address: row.bytes_at(log_column::ADDRESS)?,
            topics: std::array::from_fn(|topic| row.bytes_at(log_column::TOPIC0 + topic)),
        })
    }

    /// Topics up to the last present one.
    pub(crate) fn topic_count(&self) -> usize {
        self.topics
            .iter()
            .rposition(Option::is_some)
            .map_or(0, |last| last + 1)
    }
}

/// A log's stored fields, borrowed from wherever the source holds them.
pub(crate) struct LogRow<'a> {
    pub(crate) block_number: u64,
    pub(crate) log_index: Option<u64>,
    pub(crate) transaction_index: u64,
    pub(crate) address: &'a [u8],
    pub(crate) topics: [Option<&'a [u8]>; 4],
    pub(crate) data: &'a [u8],
}

/// Appends a log. A log without its index can't be keyed.
pub(crate) fn push_log_row(builder: &mut ChunkBuilder, log: &LogRow) -> Result<()> {
    let log_index = log.log_index.context("log.logIndex missing")?;
    anyhow::ensure!(
        log_index <= MAX_POSITION,
        "log.logIndex {log_index} is past what the buffer keys hold"
    );
    builder.push_row(make_key(log.block_number, log_index), 0, 0);
    builder.set_u64(log_column::TRANSACTION_INDEX, log.transaction_index);
    builder.set_bytes(log_column::ADDRESS, log.address);
    for (position, topic) in log.topics.iter().enumerate() {
        builder.set_optional_bytes(log_column::TOPIC0 + position, *topic);
    }
    builder.set_bytes(log_column::DATA, log.data);
    Ok(())
}

impl EvmBlockField {
    fn column_kind(self) -> ColumnKind {
        use EvmBlockField::*;
        match self {
            Number | L1BlockNumber => ColumnKind::U64,
            Hash
            | ParentHash
            | Sha3Uncles
            | TransactionsRoot
            | StateRoot
            | ReceiptsRoot
            | ParentBeaconBlockRoot
            | WithdrawalsRoot
            | SendRoot
            | MixHash => ColumnKind::Fixed(32),
            Nonce => ColumnKind::Fixed(8),
            Miner => ColumnKind::Fixed(20),
            Timestamp | LogsBloom | Difficulty | TotalDifficulty | ExtraData | Size | GasLimit
            | GasUsed | Uncles | BaseFeePerGas | BlobGasUsed | ExcessBlobGas | SendCount => {
                ColumnKind::Var
            }
        }
    }
}

pub(crate) fn blocks_schema() -> Schema {
    Schema {
        columns: EvmBlockField::VARIANTS
            .iter()
            .map(|field| field.column_kind())
            .collect(),
        has_tiebreak: false,
        has_fetched: true,
    }
}

pub(crate) const BLOCK_HASH_COLUMN: usize = EvmBlockField::Hash as usize;
pub(crate) const BLOCK_TIMESTAMP_COLUMN: usize = EvmBlockField::Timestamp as usize;
const BLOCK_NUMBER_BIT: u64 = 1 << EvmBlockField::Number as u32;

fn concat_hashes<'a>(hashes: impl Iterator<Item = &'a [u8]>) -> Vec<u8> {
    hashes.flatten().copied().collect()
}

/// Appends a HyperSync block. `fetched` is what the query asked for, so a
/// field the block has no value for still reads as fetched.
pub(crate) fn push_block(builder: &mut ChunkBuilder, block: &simple_types::Block, fetched: u64) {
    use EvmBlockField::*;
    let Some(number) = block.number else { return };
    builder.push_row(make_key(number, 0), 0, fetched | BLOCK_NUMBER_BIT);
    let set = |builder: &mut ChunkBuilder, field: EvmBlockField, value: Option<&[u8]>| {
        builder.set_optional_bytes(field as usize, value)
    };
    set(
        builder,
        Timestamp,
        block.timestamp.as_ref().map(|v| v.as_ref()),
    );
    set(builder, Hash, block.hash.as_ref().map(|v| v.as_slice()));
    set(
        builder,
        ParentHash,
        block.parent_hash.as_ref().map(|v| v.as_slice()),
    );
    set(builder, Nonce, block.nonce.as_ref().map(|v| v.as_slice()));
    set(
        builder,
        Sha3Uncles,
        block.sha3_uncles.as_ref().map(|v| v.as_slice()),
    );
    set(
        builder,
        LogsBloom,
        block.logs_bloom.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        TransactionsRoot,
        block.transactions_root.as_ref().map(|v| v.as_slice()),
    );
    set(
        builder,
        StateRoot,
        block.state_root.as_ref().map(|v| v.as_slice()),
    );
    set(
        builder,
        ReceiptsRoot,
        block.receipts_root.as_ref().map(|v| v.as_slice()),
    );
    set(builder, Miner, block.miner.as_ref().map(|v| v.as_slice()));
    set(
        builder,
        Difficulty,
        block.difficulty.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        TotalDifficulty,
        block.total_difficulty.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        ExtraData,
        block.extra_data.as_ref().map(|v| v.as_ref()),
    );
    set(builder, Size, block.size.as_ref().map(|v| v.as_ref()));
    set(
        builder,
        GasLimit,
        block.gas_limit.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        GasUsed,
        block.gas_used.as_ref().map(|v| v.as_ref()),
    );
    if let Some(uncles) = &block.uncles {
        builder.set_bytes(
            Uncles as usize,
            &concat_hashes(uncles.iter().map(|hash| hash.as_slice())),
        );
    }
    set(
        builder,
        BaseFeePerGas,
        block.base_fee_per_gas.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        BlobGasUsed,
        block.blob_gas_used.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        ExcessBlobGas,
        block.excess_blob_gas.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        ParentBeaconBlockRoot,
        block
            .parent_beacon_block_root
            .as_ref()
            .map(|v| v.as_slice()),
    );
    set(
        builder,
        WithdrawalsRoot,
        block.withdrawals_root.as_ref().map(|v| v.as_slice()),
    );
    builder.set_optional_u64(L1BlockNumber as usize, block.l1_block_number.map(u64::from));
    set(
        builder,
        SendCount,
        block.send_count.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        SendRoot,
        block.send_root.as_ref().map(|v| v.as_slice()),
    );
    set(
        builder,
        MixHash,
        block.mix_hash.as_ref().map(|v| v.as_slice()),
    );
}

/// Appends a block known only by its hash and maybe its time: an
/// observation that backs reorg detection, fetched for nothing else.
pub(crate) fn push_observed_block(
    builder: &mut ChunkBuilder,
    number: u64,
    hash: Option<&[u8]>,
    timestamp: Option<u64>,
) {
    builder.push_row(make_key(number, 0), 0, BLOCK_NUMBER_BIT);
    builder.set_optional_bytes(BLOCK_HASH_COLUMN, hash);
    if let Some(timestamp) = timestamp {
        builder.set_bytes(BLOCK_TIMESTAMP_COLUMN, &quantity_bytes(timestamp));
    }
}

fn quantity_bytes(value: u64) -> Vec<u8> {
    let bytes = value.to_be_bytes();
    let first = bytes
        .iter()
        .position(|b| *b != 0)
        .unwrap_or(bytes.len() - 1);
    bytes[first..].to_vec()
}

/// The time of a stored block row.
pub(crate) fn block_timestamp(row: &RowRef) -> Option<i64> {
    row.bytes_at(BLOCK_TIMESTAMP_COLUMN)
        .and_then(|bytes| map_i64(&Some(bytes)).ok().flatten())
}

fn block_column(
    field: EvmBlockField,
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    use EvmBlockField::*;
    let bit = 1u64 << field as u32;
    let column = field as usize;
    Ok(match field {
        Number => Column::I64(
            numbers
                .iter()
                .zip(masks)
                .map(|(number, mask)| (mask & bit != 0).then_some(*number as i64))
                .collect(),
        ),
        Timestamp => Column::I64(cells(rows, masks, bit, |row| {
            row.bytes_at(column).map_or(Ok(None), |b| map_i64(&Some(b)))
        })?),
        Hash
        | ParentHash
        | Sha3Uncles
        | LogsBloom
        | TransactionsRoot
        | StateRoot
        | ReceiptsRoot
        | ExtraData
        | ParentBeaconBlockRoot
        | WithdrawalsRoot
        | SendRoot
        | MixHash => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(crate::hex::to_hex))
        })?),
        Nonce | Difficulty | TotalDifficulty | Size | GasLimit | GasUsed | BaseFeePerGas
        | BlobGasUsed | ExcessBlobGas => Column::Big(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(U256::from_be_slice))
        })?),
        Miner => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row
                .bytes_at(column)
                .map(|b| address_text(b, should_checksum)))
        })?),
        Uncles => Column::StrVec(cells(rows, masks, bit, |row| {
            Ok(row
                .bytes_at(column)
                .map(|b| b.chunks(32).map(crate::hex::to_hex).collect()))
        })?),
        L1BlockNumber => Column::I64(cells(rows, masks, bit, |row| {
            row.u64_at(column)
                .map(|v| i64::try_from(v).context("l1BlockNumber overflow"))
                .transpose()
        })?),
        SendCount => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(hex_quantity))
        })?),
    })
}

pub(crate) fn address_text(bytes: &[u8], should_checksum: bool) -> String {
    let address = <[u8; 20]>::try_from(bytes).expect("an address cell is 20 bytes");
    encode_address(&address.into(), should_checksum)
}

/// The selected fields of the blocks at `numbers`, each row decoding the
/// fields its own mask sets. A block the table lacks gives a row of nulls.
pub(crate) fn block_columns(
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    build_columns(
        EvmBlockField::VARIANTS,
        masks,
        rows.len(),
        |field| field as u32,
        |field| field.name(),
        |field| block_column(field, rows, numbers, masks, should_checksum),
    )
}

impl EvmTxField {
    fn column_kind(self) -> ColumnKind {
        use EvmTxField::*;
        match self {
            TransactionIndex | Status | Type | L1FeeScalar => ColumnKind::U64,
            Hash | Root => ColumnKind::Fixed(32),
            From | To | ContractAddress => ColumnKind::Fixed(20),
            _ => ColumnKind::Var,
        }
    }
}

pub(crate) fn transactions_schema() -> Schema {
    Schema {
        columns: EvmTxField::VARIANTS
            .iter()
            .map(|field| field.column_kind())
            .collect(),
        has_tiebreak: false,
        has_fetched: true,
    }
}

const TRANSACTION_INDEX_BIT: u64 = 1 << EvmTxField::TransactionIndex as u32;

/// Appends a HyperSync transaction. A transaction without its key is
/// dropped: nothing can join it.
pub(crate) fn push_transaction(
    builder: &mut ChunkBuilder,
    transaction: &simple_types::Transaction,
    fetched: u64,
) -> Result<()> {
    use EvmTxField::*;
    let (Some(block_number), Some(index)) =
        (transaction.block_number, transaction.transaction_index)
    else {
        return Ok(());
    };
    builder.push_row(
        make_key(u64::from(block_number), u64::from(index)),
        0,
        fetched | TRANSACTION_INDEX_BIT,
    );
    let t = transaction;
    let set = |builder: &mut ChunkBuilder, field: EvmTxField, value: Option<&[u8]>| {
        builder.set_optional_bytes(field as usize, value)
    };
    set(builder, Hash, t.hash.as_ref().map(|v| v.as_slice()));
    set(builder, From, t.from.as_ref().map(|v| v.as_slice()));
    set(builder, To, t.to.as_ref().map(|v| v.as_slice()));
    set(builder, Gas, t.gas.as_ref().map(|v| v.as_ref()));
    set(builder, GasPrice, t.gas_price.as_ref().map(|v| v.as_ref()));
    set(
        builder,
        MaxPriorityFeePerGas,
        t.max_priority_fee_per_gas.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        MaxFeePerGas,
        t.max_fee_per_gas.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        CumulativeGasUsed,
        t.cumulative_gas_used.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        EffectiveGasPrice,
        t.effective_gas_price.as_ref().map(|v| v.as_ref()),
    );
    set(builder, GasUsed, t.gas_used.as_ref().map(|v| v.as_ref()));
    set(builder, Input, t.input.as_ref().map(|v| v.as_ref()));
    set(builder, Nonce, t.nonce.as_ref().map(|v| v.as_ref()));
    set(builder, Value, t.value.as_ref().map(|v| v.as_ref()));
    set(builder, V, t.v.as_ref().map(|v| v.as_ref()));
    set(builder, R, t.r.as_ref().map(|v| v.as_ref()));
    set(builder, S, t.s.as_ref().map(|v| v.as_ref()));
    set(
        builder,
        ContractAddress,
        t.contract_address.as_ref().map(|v| v.as_slice()),
    );
    set(
        builder,
        LogsBloom,
        t.logs_bloom.as_ref().map(|v| v.as_ref()),
    );
    set(builder, Root, t.root.as_ref().map(|v| v.as_slice()));
    builder.set_optional_u64(Status as usize, t.status.map(|v| v.to_u8() as u64));
    set(builder, YParity, t.y_parity.as_ref().map(|v| v.as_ref()));
    set(
        builder,
        MaxFeePerBlobGas,
        t.max_fee_per_blob_gas.as_ref().map(|v| v.as_ref()),
    );
    if let Some(hashes) = &t.blob_versioned_hashes {
        builder.set_bytes(
            BlobVersionedHashes as usize,
            &concat_hashes(hashes.iter().map(|hash| hash.as_slice())),
        );
    }
    builder.set_optional_u64(Type as usize, t.type_.map(|v| u8::from(v) as u64));
    set(builder, L1Fee, t.l1_fee.as_ref().map(|v| v.as_ref()));
    set(
        builder,
        L1GasPrice,
        t.l1_gas_price.as_ref().map(|v| v.as_ref()),
    );
    set(
        builder,
        L1GasUsed,
        t.l1_gas_used.as_ref().map(|v| v.as_ref()),
    );
    builder.set_optional_u64(L1FeeScalar as usize, t.l1_fee_scalar.map(f64::to_bits));
    set(
        builder,
        GasUsedForL1,
        t.gas_used_for_l1.as_ref().map(|v| v.as_ref()),
    );
    if let Some(access_list) = &t.access_list {
        builder.set_bytes(
            AccessList as usize,
            &serde_json::to_vec(access_list).context("encode transaction.accessList")?,
        );
    }
    if let Some(authorization_list) = &t.authorization_list {
        builder.set_bytes(
            AuthorizationList as usize,
            &serde_json::to_vec(authorization_list)
                .context("encode transaction.authorizationList")?,
        );
    }
    Ok(())
}

fn transaction_column(
    field: EvmTxField,
    rows: &[Option<RowRef>],
    indexes: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    use EvmTxField::*;
    let bit = 1u64 << field as u32;
    let column = field as usize;
    Ok(match field {
        TransactionIndex => Column::I64(
            indexes
                .iter()
                .zip(masks)
                .map(|(index, mask)| (mask & bit != 0).then_some(*index as i64))
                .collect(),
        ),
        Hash | Input | LogsBloom | Root => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(crate::hex::to_hex))
        })?),
        From | To | ContractAddress => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row
                .bytes_at(column)
                .map(|b| address_text(b, should_checksum)))
        })?),
        Gas | GasPrice | MaxPriorityFeePerGas | MaxFeePerGas | CumulativeGasUsed
        | EffectiveGasPrice | GasUsed | Nonce | Value | MaxFeePerBlobGas | L1Fee | L1GasPrice
        | L1GasUsed | GasUsedForL1 => Column::Big(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(U256::from_be_slice))
        })?),
        V | R | S | YParity => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(hex_quantity))
        })?),
        Status | Type => Column::I64(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(|v| v as i64))
        })?),
        BlobVersionedHashes => Column::StrVec(cells(rows, masks, bit, |row| {
            Ok(row
                .bytes_at(column)
                .map(|b| b.chunks(32).map(crate::hex::to_hex).collect()))
        })?),
        L1FeeScalar => Column::F64(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(f64::from_bits))
        })?),
        AccessList => Column::AccessList(cells(rows, masks, bit, |row| {
            row.bytes_at(column)
                .map(|b| {
                    let list: Vec<format::AccessList> =
                        serde_json::from_slice(b).context("decode transaction.accessList")?;
                    Ok(list.iter().map(AccessListItem::from).collect())
                })
                .transpose()
        })?),
        AuthorizationList => Column::AuthList(cells(rows, masks, bit, |row| {
            row.bytes_at(column)
                .map(|b| {
                    let list: Vec<format::Authorization> = serde_json::from_slice(b)
                        .context("decode transaction.authorizationList")?;
                    list.iter().map(AuthorizationItem::try_from).collect()
                })
                .transpose()
        })?),
    })
}

/// The selected fields of the transactions of `rows`, each row decoding the
/// fields its own mask sets.
pub(crate) fn transaction_columns(
    rows: &[Option<RowRef>],
    indexes: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    build_columns(
        EvmTxField::VARIANTS,
        masks,
        rows.len(),
        |field| field as u32,
        |field| field.name(),
        |field| transaction_column(field, rows, indexes, masks, should_checksum),
    )
}

/// A hash as JS spells it.
pub(crate) fn hash_text(bytes: &[u8]) -> String {
    crate::hex::to_hex(bytes)
}

/// A JS hash back to its bytes: exactly 32, or the comparison against a
/// fetched hash would report a reorg that isn't one.
pub(crate) fn hash_bytes(text: &str) -> Result<Vec<u8>> {
    let bytes = crate::hex::decode_prefixed(text, "block.hash")?;
    anyhow::ensure!(
        bytes.len() == 32,
        "block.hash '{text}' must be 32 bytes, got {}",
        bytes.len()
    );
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chain_buffer::tables::table::Table;

    #[test]
    fn a_block_reads_back_the_fields_its_mask_selects() {
        use hypersync_client::format::{Hash, Quantity};
        let mut table = Table::new(blocks_schema());
        let mut builder = table.builder();
        let block = simple_types::Block {
            number: Some(7),
            hash: Some(Hash::from([0xab; 32])),
            timestamp: Some(Quantity::from(vec![0x01, 0x00])),
            gas_used: Some(Quantity::from(vec![0x05])),
            ..Default::default()
        };
        push_block(&mut builder, &block, u64::MAX);
        table.merge(builder.finish());
        let row = table.find(make_key(7, 0), 0);
        let mask = (1 << EvmBlockField::Number as u64)
            | (1 << EvmBlockField::Timestamp as u64)
            | (1 << EvmBlockField::GasUsed as u64);
        let columns = block_columns(&[row], &[7], &[mask], false).unwrap();
        let described: Vec<(&str, String)> = columns
            .columns
            .iter()
            .map(|(name, column)| {
                (
                    *name,
                    match column {
                        Column::I64(values) => format!("{values:?}"),
                        Column::Big(values) => format!("{values:?}"),
                        _ => "other".to_string(),
                    },
                )
            })
            .collect();
        assert_eq!(
            described,
            vec![
                ("number", "[Some(7)]".to_string()),
                ("timestamp", "[Some(256)]".to_string()),
                ("gasUsed", "[Some(5)]".to_string()),
            ]
        );
    }
}
