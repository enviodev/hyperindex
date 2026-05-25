use anyhow::{Context, Result};
use hypersync_client::{format::Hex, net_types};
use napi::bindgen_prelude::Either;
use napi_derive::napi;

/// Filter for selecting logs based on address and topics
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct LogFilter {
    /// Address of the contract, any logs that has any of these addresses will be returned.
    /// Empty means match all.
    pub address: Option<Vec<String>>,
    /// Topics to match, each member of the top level array is another array, if the nth topic matches any
    ///  topic specified in topics[n] the log will be returned. Empty means match all.
    pub topics: Option<Vec<Vec<String>>>,
}

/// Selection criteria for logs with include and exclude filters
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct LogSelection {
    /// Logs that match this filter will be included
    pub include: LogFilter,
    /// Logs that match this filter will be excluded
    pub exclude: Option<LogFilter>,
}

/// Filter for selecting transactions based on various criteria
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct TransactionFilter {
    /// Address the transaction should originate from. If transaction.from matches any of these, the transaction
    ///  will be returned. Keep in mind that this has an and relationship with to filter, so each transaction should
    ///  match both of them. Empty means match all.
    pub from: Option<Vec<String>>,
    /// Address the transaction should go to. If transaction.to matches any of these, the transaction will
    ///  be returned. Keep in mind that this has an and relationship with from filter, so each transaction should
    ///  match both of them. Empty means match all.
    pub to: Option<Vec<String>>,
    /// If first 4 bytes of transaction input matches any of these, transaction will be returned. Empty means match all.
    pub sighash: Option<Vec<String>>,
    /// If tx.status matches this it will be returned.
    pub status: Option<i64>,
    /// If transaction.type matches any of these values, the transaction will be returned
    #[napi(js_name = "type")]
    pub type_: Option<Vec<u8>>,
    // If transaction.contract_address matches any of these values, the transaction will be returned.
    pub contract_address: Option<Vec<String>>,
    /// If transaction.hash matches any of these values, the transaction will be returned.
    /// Empty means match all.
    pub hash: Option<Vec<String>>,

    /// If transaction.authorization_list matches any of these values, the transaction will be returned.
    pub authorization_list: Option<Vec<AuthorizationSelection>>,
}

/// Selection criteria for transactions with include and exclude filters
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct TransactionSelection {
    /// Transactions that match this filter will be included
    pub include: TransactionFilter,
    /// Transactions that match this filter will be excluded
    pub exclude: Option<TransactionFilter>,
}

/// Selection criteria for transaction authorization lists
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct AuthorizationSelection {
    /// List of chain ids to match in the transaction authorizationList
    pub chain_id: Option<Vec<i64>>,
    /// List of addresses to match in the transaction authorizationList
    pub address: Option<Vec<String>>,
}

/// Selection of specific fields to return for each data type
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct FieldSelection {
    /// Block fields to include in the response
    pub block: Option<Vec<BlockField>>,
    /// Transaction fields to include in the response
    pub transaction: Option<Vec<TransactionField>>,
    /// Log fields to include in the response
    pub log: Option<Vec<LogField>>,
}

/// Available fields for block data
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
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

/// Available fields for transaction data
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
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

/// Available fields for log data
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogField {
    Removed,
    LogIndex,
    TransactionIndex,
    TransactionHash,
    BlockHash,
    BlockNumber,
    Address,
    Data,
    Topic0,
    Topic1,
    Topic2,
    Topic3,
}

/// Filter for selecting blocks based on hash and miner
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct BlockFilter {
    /// Hash of a block, any blocks that have one of these hashes will be returned.
    /// Empty means match all.
    pub hash: Option<Vec<String>>,
    /// Miner address of a block, any blocks that have one of these miners will be returned.
    /// Empty means match all.
    pub miner: Option<Vec<String>>,
}

/// Selection criteria for blocks with include and exclude filters
#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct BlockSelection {
    /// Blocks that match this filter will be included
    pub include: BlockFilter,
    /// Blocks that match this filter will be excluded
    pub exclude: Option<BlockFilter>,
}

/// Mode for joining blockchain data
#[napi]
#[derive(Default, Debug, PartialEq, Eq, Clone, Copy)]
pub enum JoinMode {
    /// Default join mode
    #[default]
    Default,
    /// Join all available data
    JoinAll,
    /// Join no additional data
    JoinNothing,
}

/// Query for retrieving blockchain data
#[napi(object)]
#[derive(Default, Clone)]
pub struct Query {
    /// The block to start the query from
    pub from_block: i64,
    /// The block to end the query at. If not specified, the query will go until the
    ///  end of data. Exclusive, the returned range will be [from_block..to_block).
    ///
    /// The query will return before it reaches this target block if it hits the time limit
    ///  configured on the server. The user should continue their query by putting the
    ///  next_block field in the response into from_block field of their next query. This implements
    ///  pagination.
    pub to_block: Option<i64>,
    /// List of log selections, these have an or relationship between them, so the query will return logs
    /// that match any of these selections.
    pub logs: Option<Vec<Either<LogSelection, LogFilter>>>,
    /// List of transaction selections, the query will return transactions that match any of these selections and
    ///  it will return transactions that are related to the returned logs.
    pub transactions: Option<Vec<Either<TransactionSelection, TransactionFilter>>>,
    /// List of block selections, the query will return blocks that match any of these selections
    pub blocks: Option<Vec<Either<BlockSelection, BlockFilter>>>,
    /// Weather to include all blocks regardless of if they are related to a returned transaction or log. Normally
    ///  the server will return only the blocks that are related to the transaction or logs in the response. But if this
    ///  is set to true, the server will return data for all blocks in the requested range [from_block, to_block).
    pub include_all_blocks: Option<bool>,
    /// Field selection. The user can select which fields they are interested in, requesting less fields will improve
    ///  query execution time and reduce the payload size so the user should always use a minimal number of fields.
    pub field_selection: FieldSelection,
    /// Maximum number of blocks that should be returned, the server might return more blocks than this number but
    ///  it won't overshoot by too much.
    pub max_num_blocks: Option<i64>,
    /// Maximum number of transactions that should be returned, the server might return more transactions than this number but
    ///  it won't overshoot by too much.
    pub max_num_transactions: Option<i64>,
    /// Maximum number of logs that should be returned, the server might return more logs than this number but
    ///  it won't overshoot by too much.
    pub max_num_logs: Option<i64>,
    /// Selects join mode for the query,
    /// Default: join in this order logs -> transactions -> traces -> blocks
    /// JoinAll: join everything to everything. For example if logSelection matches log0, we get the
    /// associated transaction of log0 and then we get associated logs of that transaction as well. Applites similarly
    /// to blocks, traces.
    /// JoinNothing: join nothing.
    pub join_mode: Option<JoinMode>,
}

impl TryFrom<Query> for net_types::Query {
    type Error = anyhow::Error;

    fn try_from(query: Query) -> Result<net_types::Query> {
        let logs = if let Some(log_filters) = query.logs {
            log_filters
                .into_iter()
                .map(|either| match either {
                    Either::A(selection) => net_types::LogSelection::try_from(selection),
                    Either::B(filter) => {
                        let net_filter = net_types::LogFilter::try_from(filter)?;
                        Ok(net_types::LogSelection::new(net_filter))
                    }
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            Vec::new()
        };

        let transactions = if let Some(transaction_filters) = query.transactions {
            transaction_filters
                .into_iter()
                .map(|either| match either {
                    Either::A(selection) => net_types::TransactionSelection::try_from(selection),
                    Either::B(filter) => {
                        let net_filter = net_types::TransactionFilter::try_from(filter)?;
                        Ok(net_types::TransactionSelection::new(net_filter))
                    }
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            Vec::new()
        };

        let blocks = if let Some(block_filters) = query.blocks {
            block_filters
                .into_iter()
                .map(|either| match either {
                    Either::A(selection) => net_types::BlockSelection::try_from(selection),
                    Either::B(filter) => {
                        let net_filter = net_types::BlockFilter::try_from(filter)?;
                        Ok(net_types::BlockSelection::new(net_filter))
                    }
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            Vec::new()
        };

        let field_selection = net_types::FieldSelection::try_from(query.field_selection)?;

        let join_mode = match query.join_mode.unwrap_or(JoinMode::Default) {
            JoinMode::Default => net_types::JoinMode::Default,
            JoinMode::JoinAll => net_types::JoinMode::JoinAll,
            JoinMode::JoinNothing => net_types::JoinMode::JoinNothing,
        };

        Ok(net_types::Query {
            from_block: query.from_block as u64,
            to_block: query.to_block.map(|b| b as u64),
            logs,
            transactions,
            traces: Vec::new(),
            blocks,
            include_all_blocks: query.include_all_blocks.unwrap_or(false),
            field_selection,
            max_num_blocks: query.max_num_blocks.map(|n| n as usize),
            max_num_transactions: query.max_num_transactions.map(|n| n as usize),
            max_num_logs: query.max_num_logs.map(|n| n as usize),
            max_num_traces: None,
            join_mode,
        })
    }
}

impl TryFrom<LogFilter> for net_types::LogFilter {
    type Error = anyhow::Error;

    fn try_from(filter: LogFilter) -> Result<net_types::LogFilter> {
        use arrayvec::ArrayVec;
        use hypersync_client::format::LogArgument;

        let address = map_optional_vec(filter.address).context("Failed to parse address")?;

        let mut topics = ArrayVec::new();
        if let Some(topic_vecs) = filter.topics {
            for (i, topic_vec) in topic_vecs.into_iter().enumerate() {
                if i >= 4 {
                    anyhow::bail!("Log filter has more than 4 topics");
                }
                let parsed_topics = topic_vec
                    .into_iter()
                    .map(|topic_str| LogArgument::try_from(topic_str.as_str()))
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .context("Failed to parse topic")?;
                topics.push(parsed_topics);
            }
        }

        Ok(net_types::LogFilter {
            address,
            address_filter: None,
            topics,
        })
    }
}

impl TryFrom<LogSelection> for net_types::LogSelection {
    type Error = anyhow::Error;

    fn try_from(selection: LogSelection) -> Result<net_types::LogSelection> {
        let include = net_types::LogFilter::try_from(selection.include)?;
        let exclude = selection
            .exclude
            .map(net_types::LogFilter::try_from)
            .transpose()?;

        Ok(net_types::LogSelection { include, exclude })
    }
}

impl TryFrom<AuthorizationSelection> for net_types::AuthorizationSelection {
    type Error = anyhow::Error;

    fn try_from(selection: AuthorizationSelection) -> Result<net_types::AuthorizationSelection> {
        let chain_id = selection
            .chain_id
            .unwrap_or_default()
            .into_iter()
            .map(|id| id as u64)
            .collect();

        let address =
            map_optional_vec(selection.address).context("Failed to parse authorization address")?;

        Ok(net_types::AuthorizationSelection { chain_id, address })
    }
}

fn map_optional_vec<T, U, E>(v: Option<Vec<T>>) -> std::result::Result<Vec<U>, E>
where
    T: TryInto<U, Error = E>,
    U: std::fmt::Debug,
{
    if let Some(ve) = v {
        ve.into_iter()
            .map(TryInto::try_into)
            .collect::<std::result::Result<Vec<_>, _>>()
    } else {
        Ok(Vec::new())
    }
}

impl TryFrom<TransactionFilter> for net_types::TransactionFilter {
    type Error = anyhow::Error;

    fn try_from(filter: TransactionFilter) -> Result<net_types::TransactionFilter> {
        Ok(net_types::TransactionFilter {
            from: map_optional_vec(filter.from).context("Failed to convert from")?,
            from_filter: None,
            to: map_optional_vec(filter.to).context("Failed to convert to")?,
            to_filter: None,
            sighash: map_optional_vec(filter.sighash).context("Failed to convert sighash")?,
            status: filter.status.map(|s| s as u8),
            type_: filter.type_.unwrap_or_default(),
            contract_address: map_optional_vec(filter.contract_address)
                .context("Failed to convert contract_address")?,
            contract_address_filter: None,
            hash: map_optional_vec(filter.hash).context("Failed to convert hash")?,
            authorization_list: map_optional_vec(filter.authorization_list)
                .context("Failed to convert authorization_list")?,
        })
    }
}

impl TryFrom<TransactionSelection> for net_types::TransactionSelection {
    type Error = anyhow::Error;

    fn try_from(selection: TransactionSelection) -> Result<net_types::TransactionSelection> {
        let include = net_types::TransactionFilter::try_from(selection.include)?;
        let exclude = selection
            .exclude
            .map(net_types::TransactionFilter::try_from)
            .transpose()?;

        Ok(net_types::TransactionSelection { include, exclude })
    }
}

impl TryFrom<BlockFilter> for net_types::BlockFilter {
    type Error = anyhow::Error;

    fn try_from(filter: BlockFilter) -> Result<net_types::BlockFilter> {
        use hypersync_client::format::{Address, Hash};

        let hash = if let Some(hashes) = filter.hash {
            hashes
                .into_iter()
                .map(|hash_str| Hash::try_from(hash_str.as_str()))
                .collect::<std::result::Result<Vec<_>, _>>()
                .context("Failed to parse hash")?
        } else {
            Vec::new()
        };

        let miner = if let Some(addresses) = filter.miner {
            addresses
                .into_iter()
                .map(|addr_str| Address::try_from(addr_str.as_str()))
                .collect::<std::result::Result<Vec<_>, _>>()
                .context("Failed to parse miner address")?
        } else {
            Vec::new()
        };

        Ok(net_types::BlockFilter { hash, miner })
    }
}

impl TryFrom<BlockSelection> for net_types::BlockSelection {
    type Error = anyhow::Error;

    fn try_from(selection: BlockSelection) -> Result<net_types::BlockSelection> {
        let include = net_types::BlockFilter::try_from(selection.include)?;
        let exclude = selection
            .exclude
            .map(net_types::BlockFilter::try_from)
            .transpose()?;

        Ok(net_types::BlockSelection { include, exclude })
    }
}

macro_rules! field_enum_convert {
    ($local:ty, $remote:ty, [$($variant:ident),* $(,)?]) => {
        impl From<$local> for $remote {
            fn from(field: $local) -> Self {
                match field { $( <$local>::$variant => <$remote>::$variant, )* }
            }
        }
        impl From<$remote> for $local {
            fn from(field: $remote) -> Self {
                match field { $( <$remote>::$variant => <$local>::$variant, )* }
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

field_enum_convert!(
    LogField,
    net_types::LogField,
    [
        Removed,
        LogIndex,
        TransactionIndex,
        TransactionHash,
        BlockHash,
        BlockNumber,
        Address,
        Data,
        Topic0,
        Topic1,
        Topic2,
        Topic3,
    ]
);

impl TryFrom<FieldSelection> for net_types::FieldSelection {
    type Error = anyhow::Error;

    fn try_from(selection: FieldSelection) -> Result<net_types::FieldSelection> {
        use std::collections::BTreeSet;

        let block = selection
            .block
            .unwrap_or_default()
            .into_iter()
            .map(net_types::BlockField::from)
            .collect::<BTreeSet<_>>();
        let transaction = selection
            .transaction
            .unwrap_or_default()
            .into_iter()
            .map(net_types::TransactionField::from)
            .collect::<BTreeSet<_>>();
        let log = selection
            .log
            .unwrap_or_default()
            .into_iter()
            .map(net_types::LogField::from)
            .collect::<BTreeSet<_>>();

        Ok(net_types::FieldSelection {
            block,
            transaction,
            log,
            trace: BTreeSet::new(),
        })
    }
}

// Reverse conversions from net_types back to client types

impl From<net_types::Query> for Query {
    fn from(query: net_types::Query) -> Query {
        fn map_selections<T, F, S>(
            selections: Vec<net_types::Selection<T>>,
        ) -> Option<Vec<Either<S, F>>>
        where
            T: Into<F>,
            net_types::Selection<T>: Into<S>,
        {
            if selections.is_empty() {
                None
            } else {
                let mut converted = Vec::new();
                for selection in selections {
                    if selection.exclude.is_some() {
                        converted.push(Either::A(selection.into()));
                    } else {
                        converted.push(Either::B(selection.include.into()));
                    }
                }
                Some(converted)
            }
        }

        let join_mode = Some(match query.join_mode {
            net_types::JoinMode::Default => JoinMode::Default,
            net_types::JoinMode::JoinAll => JoinMode::JoinAll,
            net_types::JoinMode::JoinNothing => JoinMode::JoinNothing,
        });

        Query {
            from_block: query.from_block as i64,
            to_block: query.to_block.map(|b| b as i64),
            logs: map_selections(query.logs),
            transactions: map_selections(query.transactions),
            blocks: map_selections(query.blocks),
            include_all_blocks: if query.include_all_blocks {
                Some(true)
            } else {
                None
            },
            field_selection: query.field_selection.into(),
            max_num_blocks: query.max_num_blocks.map(|n| n as i64),
            max_num_transactions: query.max_num_transactions.map(|n| n as i64),
            max_num_logs: query.max_num_logs.map(|n| n as i64),
            join_mode,
        }
    }
}

fn map_maybe_hex_vec<T>(v: Vec<T>) -> Option<Vec<String>>
where
    T: Hex,
{
    if v.is_empty() {
        None
    } else {
        Some(v.iter().map(Hex::encode_hex).collect())
    }
}

impl From<net_types::LogFilter> for LogFilter {
    fn from(filter: net_types::LogFilter) -> LogFilter {
        let topics = if filter.topics.is_empty() {
            None
        } else {
            Some(
                filter
                    .topics
                    .into_iter()
                    .map(|topic_vec| topic_vec.iter().map(Hex::encode_hex).collect())
                    .collect(),
            )
        };

        LogFilter {
            address: map_maybe_hex_vec(filter.address),
            topics,
        }
    }
}

impl From<net_types::LogSelection> for LogSelection {
    fn from(selection: net_types::LogSelection) -> Self {
        Self {
            include: selection.include.into(),
            exclude: selection.exclude.map(Into::into),
        }
    }
}

impl From<net_types::AuthorizationSelection> for AuthorizationSelection {
    fn from(selection: net_types::AuthorizationSelection) -> AuthorizationSelection {
        let chain_id = if selection.chain_id.is_empty() {
            None
        } else {
            Some(selection.chain_id.into_iter().map(|id| id as i64).collect())
        };

        AuthorizationSelection {
            chain_id,
            address: map_maybe_hex_vec(selection.address),
        }
    }
}

impl From<net_types::TransactionFilter> for TransactionFilter {
    fn from(filter: net_types::TransactionFilter) -> TransactionFilter {
        let status = filter.status.map(|s| s as i64);

        let type_ = if filter.type_.is_empty() {
            None
        } else {
            Some(filter.type_)
        };

        let authorization_list = if filter.authorization_list.is_empty() {
            None
        } else {
            Some(
                filter
                    .authorization_list
                    .into_iter()
                    .map(Into::into)
                    .collect::<Vec<_>>(),
            )
        };

        TransactionFilter {
            from: map_maybe_hex_vec(filter.from),
            to: map_maybe_hex_vec(filter.to),
            sighash: map_maybe_hex_vec(filter.sighash),
            status,
            type_,
            contract_address: map_maybe_hex_vec(filter.contract_address),
            hash: map_maybe_hex_vec(filter.hash),
            authorization_list,
        }
    }
}

impl From<net_types::TransactionSelection> for TransactionSelection {
    fn from(selection: net_types::TransactionSelection) -> Self {
        Self {
            include: selection.include.into(),
            exclude: selection.exclude.map(Into::into),
        }
    }
}

impl From<net_types::BlockFilter> for BlockFilter {
    fn from(filter: net_types::BlockFilter) -> BlockFilter {
        BlockFilter {
            hash: map_maybe_hex_vec(filter.hash),
            miner: map_maybe_hex_vec(filter.miner),
        }
    }
}

impl From<net_types::BlockSelection> for BlockSelection {
    fn from(selection: net_types::BlockSelection) -> Self {
        Self {
            include: selection.include.into(),
            exclude: selection.exclude.map(Into::into),
        }
    }
}

impl From<net_types::FieldSelection> for FieldSelection {
    fn from(selection: net_types::FieldSelection) -> FieldSelection {
        fn map_into<T, F>(fields: std::collections::BTreeSet<T>) -> Option<Vec<F>>
        where
            T: Into<F>,
        {
            if fields.is_empty() {
                None
            } else {
                Some(fields.into_iter().map(Into::into).collect())
            }
        }

        FieldSelection {
            block: map_into(selection.block),
            transaction: map_into(selection.transaction),
            log: map_into(selection.log),
        }
    }
}
