//! EVM tables: logs, transactions and blocks, what fills them from a source's
//! rows, and how their cells read back as the fields handlers select.

use alloy_primitives::U256;
use anyhow::{Context, Result};
use hypersync_client::format;
use hypersync_client::simple_types;
use strum::VariantArray;

use super::deliver::{build_columns, cells, hex_quantity, Column, Columns};
use super::table::{make_key, ChunkBuilder, ColumnKind, RowRef, Schema, MAX_POSITION};
use crate::evm_hypersync_source::types::{
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

/// Appends a HyperSync log. A log without its key or emitter is malformed.
pub(crate) fn push_log(builder: &mut ChunkBuilder, log: &simple_types::Log) -> Result<()> {
    let block_number = u64::from(log.block_number.context("log.blockNumber missing")?);
    let log_index = u64::from(log.log_index.context("log.logIndex missing")?);
    anyhow::ensure!(
        log_index <= MAX_POSITION,
        "log.logIndex {log_index} is past what the buffer keys hold"
    );
    builder.push_row(make_key(block_number, log_index), 0, 0);
    builder.set_u64(
        log_column::TRANSACTION_INDEX,
        u64::from(
            log.transaction_index
                .context("log.transactionIndex missing")?,
        ),
    );
    builder.set_bytes(
        log_column::ADDRESS,
        log.address
            .as_ref()
            .context("log.address missing")?
            .as_slice(),
    );
    for (position, topic) in log.topics.iter().enumerate().take(4) {
        builder.set_optional_bytes(
            log_column::TOPIC0 + position,
            topic.as_ref().map(|topic| topic.as_slice()),
        );
    }
    builder.set_bytes(
        log_column::DATA,
        log.data.as_ref().map(|data| data.as_ref()).unwrap_or(&[]),
    );
    Ok(())
}

/// Block field codes shared with ReScript by ordinal: the order mirrors
/// `Evm.res` `blockFields`, and the ordinal is the field's bit in a selection
/// mask and its column in the blocks table.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub(crate) enum EvmBlockField {
    Number = 0,
    Timestamp = 1,
    Hash = 2,
    ParentHash = 3,
    Nonce = 4,
    Sha3Uncles = 5,
    LogsBloom = 6,
    TransactionsRoot = 7,
    StateRoot = 8,
    ReceiptsRoot = 9,
    Miner = 10,
    Difficulty = 11,
    TotalDifficulty = 12,
    ExtraData = 13,
    Size = 14,
    GasLimit = 15,
    GasUsed = 16,
    Uncles = 17,
    BaseFeePerGas = 18,
    BlobGasUsed = 19,
    ExcessBlobGas = 20,
    ParentBeaconBlockRoot = 21,
    WithdrawalsRoot = 22,
    L1BlockNumber = 23,
    SendCount = 24,
    SendRoot = 25,
    MixHash = 26,
}

impl EvmBlockField {
    pub(crate) fn name(self) -> &'static str {
        use EvmBlockField::*;
        match self {
            Number => "number",
            Timestamp => "timestamp",
            Hash => "hash",
            ParentHash => "parentHash",
            Nonce => "nonce",
            Sha3Uncles => "sha3Uncles",
            LogsBloom => "logsBloom",
            TransactionsRoot => "transactionsRoot",
            StateRoot => "stateRoot",
            ReceiptsRoot => "receiptsRoot",
            Miner => "miner",
            Difficulty => "difficulty",
            TotalDifficulty => "totalDifficulty",
            ExtraData => "extraData",
            Size => "size",
            GasLimit => "gasLimit",
            GasUsed => "gasUsed",
            Uncles => "uncles",
            BaseFeePerGas => "baseFeePerGas",
            BlobGasUsed => "blobGasUsed",
            ExcessBlobGas => "excessBlobGas",
            ParentBeaconBlockRoot => "parentBeaconBlockRoot",
            WithdrawalsRoot => "withdrawalsRoot",
            L1BlockNumber => "l1BlockNumber",
            SendCount => "sendCount",
            SendRoot => "sendRoot",
            MixHash => "mixHash",
        }
    }

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

/// Transaction field codes shared with ReScript by ordinal: the order mirrors
/// `Evm.res` `transactionFields`, and the ordinal is the field's bit in a
/// selection mask and its column in the transactions table.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub(crate) enum EvmTxField {
    TransactionIndex = 0,
    Hash = 1,
    From = 2,
    To = 3,
    Gas = 4,
    GasPrice = 5,
    MaxPriorityFeePerGas = 6,
    MaxFeePerGas = 7,
    CumulativeGasUsed = 8,
    EffectiveGasPrice = 9,
    GasUsed = 10,
    Input = 11,
    Nonce = 12,
    Value = 13,
    V = 14,
    R = 15,
    S = 16,
    ContractAddress = 17,
    LogsBloom = 18,
    Root = 19,
    Status = 20,
    YParity = 21,
    MaxFeePerBlobGas = 22,
    BlobVersionedHashes = 23,
    Type = 24,
    L1Fee = 25,
    L1GasPrice = 26,
    L1GasUsed = 27,
    L1FeeScalar = 28,
    GasUsedForL1 = 29,
    AccessList = 30,
    AuthorizationList = 31,
}

impl EvmTxField {
    pub(crate) fn name(self) -> &'static str {
        use EvmTxField::*;
        match self {
            TransactionIndex => "transactionIndex",
            Hash => "hash",
            From => "from",
            To => "to",
            Gas => "gas",
            GasPrice => "gasPrice",
            MaxPriorityFeePerGas => "maxPriorityFeePerGas",
            MaxFeePerGas => "maxFeePerGas",
            CumulativeGasUsed => "cumulativeGasUsed",
            EffectiveGasPrice => "effectiveGasPrice",
            GasUsed => "gasUsed",
            Input => "input",
            Nonce => "nonce",
            Value => "value",
            V => "v",
            R => "r",
            S => "s",
            ContractAddress => "contractAddress",
            LogsBloom => "logsBloom",
            Root => "root",
            Status => "status",
            YParity => "yParity",
            MaxFeePerBlobGas => "maxFeePerBlobGas",
            BlobVersionedHashes => "blobVersionedHashes",
            Type => "type",
            L1Fee => "l1Fee",
            L1GasPrice => "l1GasPrice",
            L1GasUsed => "l1GasUsed",
            L1FeeScalar => "l1FeeScalar",
            GasUsedForL1 => "gasUsedForL1",
            AccessList => "accessList",
            AuthorizationList => "authorizationList",
        }
    }

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
    use crate::chain_buffer::table::Table;

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
