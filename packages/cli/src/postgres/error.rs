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
    chain_of(error)
}

/// Every cause, in order, with the ones that only repeat what is already there
/// left out.
///
/// A connection failure arrives as several layers saying the same thing — the
/// pool, the driver and OpenSSL each restate the handshake — and printing the
/// chain as it comes gives the same sentence three times over the one detail
/// that says what to fix.
fn chain_of(error: &anyhow::Error) -> String {
    let mut parts: Vec<String> = Vec::new();
    for cause in error.chain() {
        let text = cause.to_string();
        if parts.iter().any(|part| part.contains(&text)) {
            continue;
        }
        parts.retain(|part| !text.contains(part.as_str()));
        parts.push(text);
    }
    parts.join(": ")
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

    /// The layer that only restates the one below it is dropped, and the detail
    /// underneath both is kept.
    #[test]
    fn a_cause_already_spelled_out_above_is_not_repeated() {
        let error = anyhow::anyhow!("certificate verify failed")
            .context("handshake failed: certificate verify failed")
            .context("handshake failed")
            .context("Failed taking a connection");
        assert_eq!(
            message_of(&error),
            "Failed taking a connection: handshake failed: certificate verify failed"
        );
    }
}
