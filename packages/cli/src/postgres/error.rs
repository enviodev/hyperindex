//! What a failure reads as on the other side of the boundary.
//!
//! The storage layer classifies a write failure by its message, matching the
//! server's text exactly — a NUL in a text column and a NUL refused by `jsonb`
//! are what send it back to retry the table with the value stripped, and the
//! aborted-transaction cascade is what it ignores so the first failure is the
//! one reported.
//!
//! The driver being replaced surfaced the server's message and nothing else, so
//! that is what has to arrive here. Wrapping it in the context of the call that
//! made it would read fine and match none of those cases.

/// The server's own message, where the failure came from the server.
///
/// Anything else — a connection that would not open, a pool that timed out —
/// has no server message and is reported with the context it was given.
pub fn message_of(error: &anyhow::Error) -> String {
    for cause in error.chain() {
        if let Some(database) = cause
            .downcast_ref::<tokio_postgres::Error>()
            .and_then(tokio_postgres::Error::as_db_error)
        {
            return database.message().to_string();
        }
    }
    format!("{error:#}")
}

pub fn to_napi(error: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(message_of(&error))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Nothing in the chain came from the server, so the context is all there
    /// is to report.
    #[test]
    fn a_failure_with_no_server_behind_it_keeps_its_context() {
        let error = anyhow::anyhow!("the socket closed").context("Failed taking a connection");
        assert_eq!(
            message_of(&error),
            "Failed taking a connection: the socket closed"
        );
    }
}
