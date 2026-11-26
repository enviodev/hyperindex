//! What a source call can fail with. A source never throws for one of these;
//! the caller matches on the kind.

use napi_derive::napi;

/// Crosses napi as `{kind, ...fields}`, which is the runtime shape of the
/// ReScript `Source.failure` variant, so nothing decodes it.
#[napi(discriminant = "kind")]
#[derive(Debug, Clone, PartialEq)]
pub enum SourceFailure {
    /// The backend asked to be left alone until its window resets.
    RateLimited { reset_ms: u32 },
    /// The backend instance that answered hasn't reached `block_number` yet.
    BehindHead { block_number: u32 },
    /// Ask again for the same range ending at `to_block`, with no wait.
    NarrowRange {
        to_block: u32,
        attempted_to_block: u32,
    },
    /// Wait, then ask again. Without `backoff_millis` the caller's schedule
    /// decides how long.
    Backoff {
        message: String,
        backoff_millis: Option<u32>,
        cause: Option<String>,
    },
    /// This source can't answer this query, though it isn't broken.
    WrongSourceForQuery {
        message: String,
        cause: Option<String>,
    },
    /// This source can never serve the chain's selection.
    Unusable {
        message: String,
        block_number: Option<u32>,
        cause: Option<String>,
    },
}

/// How a client call failed, before the source says what it means for the
/// caller.
#[derive(Debug)]
pub(crate) enum ClientError {
    RateLimited {
        reset_ms: u64,
    },
    BehindHead {
        block_number: u64,
    },
    /// The response lacked fields the page must carry.
    MissingFields(Vec<String>),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ClientError {
    fn from(error: anyhow::Error) -> Self {
        ClientError::Other(error)
    }
}
