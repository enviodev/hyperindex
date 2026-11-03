//! What a failure reads as on the other side of the boundary.
//!
//! A failure the server raised arrives as the server's own message, with its
//! SQLSTATE as the message of the error's `cause`. The storage layer classifies
//! on the code: the message is translated into the server's `lc_messages`.

/// The server's own message, where the failure came from the server, laid out
/// the way psql prints it.
///
/// Anything else — a connection that would not open, a pool that timed out —
/// has no server message and is reported with the context it was given.
pub fn message_of(error: &anyhow::Error) -> String {
    match database_error(error) {
        Some(database) => {
            let mut message = match error.downcast_ref::<Explained>() {
                Some(Explained(explanation)) => format!("{explanation}\n"),
                None => String::new(),
            };
            message.push_str(database.message());
            if let Some(detail) = database.detail() {
                message.push_str(&format!("\nDETAIL:  {detail}"));
            }
            if let Some(hint) = database.hint() {
                message.push_str(&format!("\nHINT:  {hint}"));
            }
            message
        }
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

/// What a server failure means for the indexer's schema, where that is known.
/// Attached as context, it leads the message with the server's own below it.
#[derive(Debug)]
pub struct Explained(pub String);

impl std::fmt::Display for Explained {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
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

/// Whether the failure is the connection going rather than anything the
/// statement or its data did: the server ending the session or shutting down,
/// the socket dropping, or a new connection refused or cut off while the server
/// is away. Nothing the failed statement sent is known to have run.
pub fn is_connection_lost(error: &anyhow::Error) -> bool {
    if let Some(database) = database_error(error) {
        let code = database.code().code();
        return code.starts_with("08") || matches!(code, "57P01" | "57P02" | "57P03");
    }
    error.chain().any(|cause| {
        cause
            .downcast_ref::<tokio_postgres::Error>()
            .is_some_and(tokio_postgres::Error::is_closed)
            || cause.is::<std::io::Error>()
            || matches!(
                cause.downcast_ref::<deadpool_postgres::PoolError>(),
                Some(deadpool_postgres::PoolError::Timeout(
                    deadpool_postgres::TimeoutType::Create
                ))
            )
    })
}

/// What a lost connection crosses the boundary as, whatever the server or the
/// socket said: the one code the indexer reads, to send an idempotent statement
/// again.
pub const CONNECTION_LOST: &str = "08006";

/// napi only puts its own status names in an error's `code`, so the SQLSTATE
/// travels as the message of a `cause`.
pub fn to_napi(error: anyhow::Error) -> napi::Error {
    let mut napi_error = napi::Error::from_reason(message_of(&error));
    let code = if is_connection_lost(&error) {
        Some(CONNECTION_LOST)
    } else {
        sql_state(&error)
    };
    if let Some(code) = code {
        napi_error.set_cause(napi::Error::from_reason(code));
    }
    napi_error
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A port that accepts and closes straight away is what a pooler or a
    /// proxy in front of a restarting database answers with.
    #[tokio::test]
    async fn a_connection_cut_off_while_opening_is_lost() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                drop(socket);
            }
        });
        let client =
            super::super::client::PgClient::connect(super::super::client::PgConnectionOptions {
                host: "127.0.0.1".to_string(),
                port,
                user: "postgres".to_string(),
                password: String::new(),
                database: "postgres".to_string(),
                ssl: super::super::client::SslSetting::Disable,
                max_connections: 1,
                application_name: None,
                extra_ca_file: None,
                connect_timeout: std::time::Duration::from_secs(5),
            })
            .unwrap();

        let error = client.begin().await.err().unwrap();

        assert!(is_connection_lost(&error), "{error:#}");
    }

    /// A failure with nothing from the driver behind it says nothing about the
    /// connection, and writing again would only fail the same way.
    #[test]
    fn a_failure_of_our_own_is_not_a_lost_connection() {
        let error = anyhow::anyhow!("Internal error: 2 values for 3 columns");
        assert!(!is_connection_lost(&error));
    }

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
