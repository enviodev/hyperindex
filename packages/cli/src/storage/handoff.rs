//! How two stores write one batch so that it lands in both or commits in
//! neither.

use std::future::Future;
use std::pin::Pin;

#[derive(Debug)]
pub struct Failure {
    pub context: String,
    pub error: anyhow::Error,
}

impl Failure {
    pub fn new(context: impl Into<String>, error: anyhow::Error) -> Self {
        Self {
            context: context.into(),
            error,
        }
    }
}

/// Settles with whether a store may commit what it wrote.
pub type Gate = Pin<Box<dyn Future<Output = bool> + Send>>;

/// How a store's half of a batch meets the other store's: it says once its
/// rows have landed, and commits only when the other side says so.
#[derive(Default)]
pub struct Handoff {
    pub landed: Option<tokio::sync::oneshot::Sender<bool>>,
    pub commit: Option<Gate>,
    /// Told whether the store committed as soon as it knows, rather than once
    /// the rest of its write is done. Postgres reports it right at its COMMIT,
    /// which is what lets ClickHouse make the batch readable.
    pub committed: Option<tokio::sync::oneshot::Sender<bool>>,
}

impl Handoff {
    pub fn report_commit(&mut self, committed: bool) {
        if let Some(sender) = self.committed.take() {
            let _ = sender.send(committed);
        }
    }

    /// A store that fails before calling this drops `landed` unsent, which
    /// the other side reads as a no.
    pub async fn ready_to_commit(&mut self) -> bool {
        if let Some(landed) = self.landed.take() {
            let _ = landed.send(true);
        }
        match self.commit.take() {
            Some(commit) => commit.await,
            None => true,
        }
    }
}

pub enum WriteError {
    Failed(Failure),
    /// Told not to commit, so nothing here was.
    Gated,
}

impl From<Failure> for WriteError {
    fn from(failure: Failure) -> Self {
        WriteError::Failed(failure)
    }
}
