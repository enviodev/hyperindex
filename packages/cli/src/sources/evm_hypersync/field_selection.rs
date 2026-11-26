use hypersync_client::net_types;

use crate::evm::fields::{BlockField, TransactionField};

pub(super) fn field_selection(
    block: &[BlockField],
    transaction: &[TransactionField],
    log: &[net_types::LogField],
) -> net_types::FieldSelection {
    net_types::FieldSelection {
        block: block.iter().copied().map(Into::into).collect(),
        transaction: transaction.iter().copied().map(Into::into).collect(),
        log: log.iter().copied().collect(),
        trace: Default::default(),
    }
}

macro_rules! field_enum_convert {
    ($local:ty, $remote:ty, [$($variant:ident),* $(,)?]) => {
        impl From<$local> for $remote {
            fn from(field: $local) -> Self {
                match field { $( <$local>::$variant => <$remote>::$variant, )* }
            }
        }
    };
}

field_enum_convert!(
    BlockField,
    net_types::BlockField,
    [
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
    ]
);

field_enum_convert!(
    TransactionField,
    net_types::TransactionField,
    [
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
    ]
);
