//! What a failure reads as on the other side of the boundary.
//!
//! A failure the server raised arrives as the server's own message, with its
//! SQLSTATE as the message of the error's `cause`. The storage layer classifies
//! on the code: the message is translated into the server's `lc_messages`.

/// The server's own message, where the failure came from the server.
///
/// Anything else — a connection that would not open, a pool that timed out —
/// has no server message and is reported with the context it was given.
pub fn message_of(error: &anyhow::Error) -> String {
    match database_error(error) {
        Some(database) => database.message().to_string(),
        None => chain_of(error),
    }
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

fn database_error(error: &anyhow::Error) -> Option<&tokio_postgres::error::DbError> {
    error.chain().find_map(|cause| {
        cause
            .downcast_ref::<tokio_postgres::Error>()
            .and_then(tokio_postgres::Error::as_db_error)
    })
}

/// A transaction that can no longer commit: a statement in it failed, or it
/// has already ended. It carries the code the server gives the same refusal,
/// so the storage layer reads it as the cascade of the failure behind it rather
/// than as a cause.
#[derive(Debug)]
pub struct Aborted(pub &'static str);

impl std::fmt::Display for Aborted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for Aborted {}

/// The SQLSTATE, where the failure came from the server or stands in for one.
pub fn sql_state(error: &anyhow::Error) -> Option<&str> {
    database_error(error)
        .map(|database| database.code().code())
        .or_else(|| {
            error
                .chain()
                .any(|cause| cause.is::<Aborted>())
                .then_some("25P02")
        })
}

/// napi only puts its own status names in an error's `code`, so the SQLSTATE
/// travels as the message of a `cause`.
pub fn to_napi(error: anyhow::Error) -> napi::Error {
    let mut napi_error = napi::Error::from_reason(message_of(&error));
    if let Some(code) = sql_state(&error) {
        napi_error.set_cause(napi::Error::from_reason(code));
    }
    napi_error
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A statement the client turns away reads as the cascade of the failure
    /// behind it, not as a failure of its own.
    #[test]
    fn a_refused_statement_carries_the_aborted_transaction_code() {
        let error = anyhow::Error::new(Aborted("The transaction has already ended"))
            .context("Failed running the statement");
        assert_eq!(sql_state(&error), Some("25P02"));
    }

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
