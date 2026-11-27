use napi_derive::napi;
use strum::VariantArray;

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
}

/// Available fields for block data
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, strum::VariantArray)]
pub enum BlockField {
    Number,
    Hash,
    ParentHash,
    Nonce,
    Sha3Uncles,
    LogsBloom,
    TransactionsRoot,
    StateRoot,
    ReceiptsRoot,
    Miner,
    Difficulty,
    TotalDifficulty,
    ExtraData,
    Size,
    GasLimit,
    GasUsed,
    Timestamp,
    Uncles,
    BaseFeePerGas,
    BlobGasUsed,
    ExcessBlobGas,
    ParentBeaconBlockRoot,
    WithdrawalsRoot,
    Withdrawals,
    L1BlockNumber,
    SendCount,
    SendRoot,
    MixHash,
}

impl BlockField {
    /// The store column this field lands in. `None` for a field the store holds
    /// no column for, which no user selection can reach — `Evm.res` offers
    /// exactly the store's fields — so it can only mean a query built with a
    /// field the store cannot serve.
    pub(crate) fn store_column(self) -> Option<EvmBlockField> {
        use BlockField as Q;
        Some(match self {
            Q::Number => EvmBlockField::Number,
            Q::Hash => EvmBlockField::Hash,
            Q::ParentHash => EvmBlockField::ParentHash,
            Q::Nonce => EvmBlockField::Nonce,
            Q::Sha3Uncles => EvmBlockField::Sha3Uncles,
            Q::LogsBloom => EvmBlockField::LogsBloom,
            Q::TransactionsRoot => EvmBlockField::TransactionsRoot,
            Q::StateRoot => EvmBlockField::StateRoot,
            Q::ReceiptsRoot => EvmBlockField::ReceiptsRoot,
            Q::Miner => EvmBlockField::Miner,
            Q::Difficulty => EvmBlockField::Difficulty,
            Q::TotalDifficulty => EvmBlockField::TotalDifficulty,
            Q::ExtraData => EvmBlockField::ExtraData,
            Q::Size => EvmBlockField::Size,
            Q::GasLimit => EvmBlockField::GasLimit,
            Q::GasUsed => EvmBlockField::GasUsed,
            Q::Timestamp => EvmBlockField::Timestamp,
            Q::Uncles => EvmBlockField::Uncles,
            Q::BaseFeePerGas => EvmBlockField::BaseFeePerGas,
            Q::BlobGasUsed => EvmBlockField::BlobGasUsed,
            Q::ExcessBlobGas => EvmBlockField::ExcessBlobGas,
            Q::ParentBeaconBlockRoot => EvmBlockField::ParentBeaconBlockRoot,
            Q::WithdrawalsRoot => EvmBlockField::WithdrawalsRoot,
            Q::L1BlockNumber => EvmBlockField::L1BlockNumber,
            Q::SendCount => EvmBlockField::SendCount,
            Q::SendRoot => EvmBlockField::SendRoot,
            Q::MixHash => EvmBlockField::MixHash,
            Q::Withdrawals => return None,
        })
    }

    /// Selection mask over store field ordinals.
    pub(crate) fn store_mask(fields: &[BlockField]) -> u64 {
        fields
            .iter()
            .filter_map(|f| f.store_column())
            .fold(0, |acc, f| acc | 1u64 << (f as u32))
    }

    /// The fields a store selection mask stands for — the inverse of
    /// `store_mask`, for turning an accumulated need back into a fetch.
    pub(crate) fn in_store_mask(mask: u64) -> Vec<BlockField> {
        BlockField::VARIANTS
            .iter()
            .copied()
            .filter(|f| {
                f.store_column()
                    .is_some_and(|c| mask & (1u64 << (c as u32)) != 0)
            })
            .collect()
    }
}

/// Available fields for transaction data
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, strum::VariantArray)]
pub enum TransactionField {
    BlockHash,
    BlockNumber,
    From,
    Gas,
    GasPrice,
    Hash,
    Input,
    Nonce,
    To,
    TransactionIndex,
    Value,
    V,
    R,
    S,
    YParity,
    MaxPriorityFeePerGas,
    MaxFeePerGas,
    ChainId,
    AccessList,
    AuthorizationList,
    MaxFeePerBlobGas,
    BlobVersionedHashes,
    CumulativeGasUsed,
    EffectiveGasPrice,
    GasUsed,
    ContractAddress,
    LogsBloom,
    Type,
    Root,
    Status,
    L1Fee,
    L1BlockNumber,
    L1GasPrice,
    L1GasUsed,
    L1FeeScalar,
    L1BaseFeeScalar,
    L1BlobBaseFee,
    L1BlobBaseFeeScalar,
    GasUsedForL1,
    Sighash,
    BlobGasPrice,
    BlobGasUsed,
    DepositNonce,
    DepositReceiptVersion,
    Mint,
    SourceHash,
}

/// Returns `Some(camelCaseFieldName)` if the user requested this field but the
/// server's response omits it AND the field isn't inherently nullable per-row.
pub(crate) fn block_field_missing(
    block: &hypersync_client::simple_types::Block,
    field: BlockField,
) -> Option<&'static str> {
    use BlockField::*;
    match field {
        // `Withdrawals` and `WithdrawalsRoot` are Shanghai-only and legitimately
        // absent on pre-Shanghai blocks; the original `evmNullableBlockFields`
        // missed `Withdrawals` — fixed here.
        Nonce
        | Difficulty
        | TotalDifficulty
        | Uncles
        | BaseFeePerGas
        | BlobGasUsed
        | ExcessBlobGas
        | ParentBeaconBlockRoot
        | WithdrawalsRoot
        | Withdrawals
        | L1BlockNumber
        | SendCount
        | SendRoot
        | MixHash => None,
        Number => block.number.is_none().then_some("number"),
        Hash => block.hash.is_none().then_some("hash"),
        ParentHash => block.parent_hash.is_none().then_some("parentHash"),
        Sha3Uncles => block.sha3_uncles.is_none().then_some("sha3Uncles"),
        LogsBloom => block.logs_bloom.is_none().then_some("logsBloom"),
        TransactionsRoot => block
            .transactions_root
            .is_none()
            .then_some("transactionsRoot"),
        StateRoot => block.state_root.is_none().then_some("stateRoot"),
        ReceiptsRoot => block.receipts_root.is_none().then_some("receiptsRoot"),
        Miner => block.miner.is_none().then_some("miner"),
        ExtraData => block.extra_data.is_none().then_some("extraData"),
        Size => block.size.is_none().then_some("size"),
        GasLimit => block.gas_limit.is_none().then_some("gasLimit"),
        GasUsed => block.gas_used.is_none().then_some("gasUsed"),
        Timestamp => block.timestamp.is_none().then_some("timestamp"),
    }
}

pub(crate) fn transaction_field_missing(
    tx: &hypersync_client::simple_types::Transaction,
    field: TransactionField,
) -> Option<&'static str> {
    use TransactionField::*;
    match field {
        GasPrice | V | R | S | YParity | MaxPriorityFeePerGas | MaxFeePerGas | MaxFeePerBlobGas
        | BlobVersionedHashes | ContractAddress | Root | Status | L1Fee | L1GasPrice
        | L1GasUsed | L1FeeScalar | GasUsedForL1 | From | To | Type => None,
        AccessList => tx.access_list.is_none().then_some("accessList"),
        AuthorizationList => tx
            .authorization_list
            .is_none()
            .then_some("authorizationList"),
        BlockHash => tx.block_hash.is_none().then_some("blockHash"),
        BlockNumber => tx.block_number.is_none().then_some("blockNumber"),
        Gas => tx.gas.is_none().then_some("gas"),
        Hash => tx.hash.is_none().then_some("hash"),
        Input => tx.input.is_none().then_some("input"),
        Nonce => tx.nonce.is_none().then_some("nonce"),
        TransactionIndex => tx.transaction_index.is_none().then_some("transactionIndex"),
        Value => tx.value.is_none().then_some("value"),
        ChainId => tx.chain_id.is_none().then_some("chainId"),
        CumulativeGasUsed => tx
            .cumulative_gas_used
            .is_none()
            .then_some("cumulativeGasUsed"),
        EffectiveGasPrice => tx
            .effective_gas_price
            .is_none()
            .then_some("effectiveGasPrice"),
        GasUsed => tx.gas_used.is_none().then_some("gasUsed"),
        LogsBloom => tx.logs_bloom.is_none().then_some("logsBloom"),
        // Enum variants not represented on simple_types::Transaction in this
        // crate version — treat as never-missing.
        L1BlockNumber
        | L1BaseFeeScalar
        | L1BlobBaseFee
        | L1BlobBaseFeeScalar
        | Sighash
        | BlobGasPrice
        | BlobGasUsed
        | DepositNonce
        | DepositReceiptVersion
        | Mint
        | SourceHash => None,
    }
}
