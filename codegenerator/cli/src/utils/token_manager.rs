use anyhow::{anyhow, Context, Result};
use keyring::Entry;

pub struct TokenManager {
    service: String,
    account: String,
}

impl TokenManager {
    pub fn new(service: &str, account: &str) -> Self {
        Self {
            service: service.to_string(),
            account: account.to_string(),
        }
    }

    fn entry(&self) -> Result<Entry> {
        Entry::new(&self.service, &self.account).context("Failed to open keyring entry")
    }

    pub fn store_token(&self, token: &str) -> Result<()> {
        self.entry()
            .and_then(|e| e.set_password(token).map_err(|e| anyhow!(e)))
            .context("Failed storing token in keyring")
    }

    pub fn get_token(&self) -> Result<Option<String>> {
        let entry = self.entry()?;
        match entry.get_password() {
            Ok(p) => Ok(Some(p)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(anyhow!(e)),
        }
    }

    pub fn clear_token(&self) -> Result<()> {
        let entry = self.entry()?;
        match entry.delete_password() {
            Ok(_) => Ok(()),
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(anyhow::Error::new(e)),
        }
    }
}

pub const SERVICE_NAME: &str = "envio-cli";
pub const JWT_ACCOUNT: &str = "oauth_token";
pub const HYPERSYNC_ACCOUNT: &str = "hypersync_api_token";

