//! The two error kinds subgraph mode reports, and the report that collects
//! them. graph-node ignores what it doesn't expect; we refuse instead, so
//! behaviour never silently diverges from the subgraph the user wrote.

use std::fmt::{self, Display};

const ISSUES_URL: &str = "https://github.com/enviodev/hyperindex/issues";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    /// A feature we recognise and deliberately don't implement.
    Unsupported { feature: String, location: String },
    /// Something we don't recognise at all: a newer subgraph feature, a newer
    /// graph-ts API, or a typo.
    Unknown { thing: String, location: String },
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
                 First, make sure you're on the latest envio version — support may have landed:\n  \
                 pnpm add -D envio@latest\n\
                 If you're up to date and need this feature, please open an issue (existing\n\
                 issues welcome a 👍 — demand drives prioritization):\n  {ISSUES_URL}"
            ),
            Finding::Unknown { thing, location } => write!(
                f,
                "Envio Subgraph doesn't know {thing}.\n  \
                 Found in {location}.\n\
                 This may be a feature newer than this envio version understands, or a typo.\n\
                 First, make sure you're on the latest envio version:\n  \
                 pnpm add -D envio@latest\n\
                 If you're up to date and this is a real subgraph feature, please open an\n\
                 issue so we can add it: {ISSUES_URL}"
            ),
        }
    }
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
