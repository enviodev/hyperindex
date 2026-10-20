//! The two error kinds subgraph mode reports, and the report that collects
//! them. graph-node ignores what it doesn't expect; we refuse instead, so
//! behaviour never silently diverges from the subgraph the user wrote.

use std::fmt::{self, Display};

use super::RPC_ENV_VAR;

const ISSUES_URL: &str = "https://github.com/enviodev/hyperindex/issues";

/// Subgraph mode ships under its own npm dist-tag (see `publish.yml`), so
/// `envio@latest` would move a project off it.
const UPGRADE_COMMAND: &str = "pnpm add -D envio@subgraph";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    /// A feature we recognise and deliberately don't implement.
    Unsupported { feature: String, location: String },
    /// Something we don't recognise at all: a newer subgraph feature, a newer
    /// graph-ts API, or a typo.
    Unknown { thing: String, location: String },
    /// A kind of subgraph whose data doesn't come from mappings over chain
    /// data, so no release of a mapping runtime can index it. `why` says where
    /// its data comes from instead.
    Unindexable {
        what: String,
        why: String,
        location: String,
    },
}

impl Finding {
    pub fn unsupported(feature: impl Into<String>, location: impl Into<String>) -> Self {
        Finding::Unsupported {
            feature: feature.into(),
            location: location.into(),
        }
    }

    pub fn unknown(thing: impl Into<String>, location: impl Into<String>) -> Self {
        Finding::Unknown {
            thing: thing.into(),
            location: location.into(),
        }
    }
}

impl Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Finding::Unsupported { feature, location } => write!(
                f,
                "Envio Subgraph doesn't support {feature} yet.\n  \
                 Found in {location}.\n\
                 First, make sure you're on the newest Envio Subgraph release — support may have \
                 landed:\n  \
                 {UPGRADE_COMMAND}\n\
                 If you're up to date and need this feature, please open an issue (existing\n\
                 issues welcome a 👍 — demand drives prioritization):\n  {ISSUES_URL}"
            ),
            Finding::Unknown { thing, location } => write!(
                f,
                "Envio Subgraph doesn't know {thing}.\n  \
                 Found in {location}.\n\
                 This may be a feature newer than this envio version understands, or a typo.\n\
                 First, make sure you're on the newest Envio Subgraph release:\n  \
                 {UPGRADE_COMMAND}\n\
                 If you're up to date and this is a real subgraph feature, please open an\n\
                 issue so we can add it: {ISSUES_URL}"
            ),
            Finding::Unindexable {
                what,
                why,
                location,
            } => write!(
                f,
                "Envio Subgraph can't index {what}.\n  \
                 Found in {location}.\n\
                 {why}\n\
                 If you need this, please open an issue so we can look at your use case:\n  \
                 {ISSUES_URL}"
            ),
        }
    }
}

/// The chain id in envio's "Failed to automatically find HyperSync endpoint for
/// the chain N" error, which says to edit a config.yaml a subgraph doesn't have.
fn hypersync_missing_chain(message: &str) -> Option<u64> {
    let rest = message
        .split("find HyperSync endpoint for the chain ")
        .nth(1)?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// An error from envio's own schema and config checks, run over what the
/// translation produced. Their messages speak about envio's config, so they are
/// framed as a translation gap: something the subgraph didn't do wrong.
pub fn envio_rejected_translation(error: anyhow::Error) -> anyhow::Error {
    if let Some(chain_id) = hypersync_missing_chain(&format!("{error:#}")) {
        return anyhow::anyhow!(
            "HyperSync doesn't serve chain {chain_id}, so Envio Subgraph has to index it over RPC.\n  \
             Set an RPC endpoint for chain {chain_id} in .env or the environment:\n  \
             {RPC_ENV_VAR}=https://...\n\
             It is one endpoint for the whole subgraph, so it suits a subgraph on this one chain."
        );
    }
    anyhow::anyhow!(
        "Envio Subgraph translated this subgraph, but envio can't index the result:\n  \
         {error:#}\n\
         First, make sure you're on the newest Envio Subgraph release:\n  \
         {UPGRADE_COMMAND}\n\
         If you're up to date, please open an issue with the message above: {ISSUES_URL}"
    )
}

/// Findings accumulated across a whole translation, so a project learns about
/// every problem in one run instead of one per attempt.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Report {
    findings: Vec<Finding>,
}

impl Report {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, finding: Finding) {
        // The same unknown field can be reached from several passes over one
        // document; report it once.
        if !self.findings.contains(&finding) {
            self.findings.push(finding);
        }
    }

    pub fn unsupported(&mut self, feature: impl Into<String>, location: impl Into<String>) {
        self.push(Finding::unsupported(feature, location));
    }

    pub fn unknown(&mut self, thing: impl Into<String>, location: impl Into<String>) {
        self.push(Finding::unknown(thing, location));
    }

    pub fn unindexable(
        &mut self,
        what: impl Into<String>,
        why: impl Into<String>,
        location: impl Into<String>,
    ) {
        self.push(Finding::Unindexable {
            what: what.into(),
            why: why.into(),
            location: location.into(),
        });
    }

    pub fn is_empty(&self) -> bool {
        self.findings.is_empty()
    }

    pub fn findings(&self) -> &[Finding] {
        &self.findings
    }

    pub fn into_result(self) -> anyhow::Result<()> {
        if self.is_empty() {
            Ok(())
        } else {
            Err(anyhow::anyhow!("{self}"))
        }
    }
}

impl Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let rendered: Vec<String> = self.findings.iter().map(|s| s.to_string()).collect();
        write!(f, "{}", rendered.join("\n\n"))
    }
}
