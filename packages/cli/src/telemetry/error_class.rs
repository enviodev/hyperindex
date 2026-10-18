use super::event::{ErrorClass, Outcome};

/// The step a command failed in, read from the context the executor wrapped
/// the error in. Matched on the context, never on the cause's message, which
/// can carry user input.
const STEP_CONTEXTS: &[(&str, ErrorClass)] = &[
    ("Failed parsing config", ErrorClass::Config),
    ("Failed parsing project paths", ErrorClass::Config),
    ("Failed parsing paths", ErrorClass::Config),
    ("Failed running codegen", ErrorClass::Codegen),
    ("Failed starting Docker containers", ErrorClass::Docker),
    ("Failed to start hasura", ErrorClass::Docker),
    (
        "Failed installing project dependencies",
        ErrorClass::PackageManager,
    ),
    ("Failed running ReScript build", ErrorClass::PackageManager),
];

/// How a failed command is reported: a cancelled prompt isn't a failure, and a
/// failure carries one coarse class rather than its message.
pub fn classify(err: &anyhow::Error) -> (Outcome, ErrorClass) {
    let cancelled = err.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<inquire::InquireError>(),
            Some(
                inquire::InquireError::OperationCanceled
                    | inquire::InquireError::OperationInterrupted
            )
        )
    });
    if cancelled {
        return (Outcome::Cancelled, ErrorClass::Other);
    }

    let by_step = err.chain().find_map(|cause| {
        let message = cause.to_string();
        STEP_CONTEXTS
            .iter()
            .find(|(context, _)| message.starts_with(context))
            .map(|(_, class)| *class)
    });
    let by_type = || {
        err.chain().find_map(|cause| {
            if cause.is::<bollard::errors::Error>() {
                Some(ErrorClass::Docker)
            } else if cause.is::<tokio_postgres::Error>() {
                Some(ErrorClass::Database)
            } else if cause.is::<reqwest::Error>() {
                Some(ErrorClass::Network)
            } else if cause.is::<serde_yaml::Error>() {
                Some(ErrorClass::Config)
            } else if cause.is::<std::io::Error>() {
                Some(ErrorClass::Io)
            } else {
                None
            }
        })
    };
    (
        Outcome::Failure,
        by_step.or_else(by_type).unwrap_or(ErrorClass::Other),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::{anyhow, Context};

    #[test]
    fn classifies_by_the_step_before_the_cause() {
        let io = || std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
        let cases = [
            Err::<(), _>(anyhow!(inquire::InquireError::OperationInterrupted))
                .context("Failed during interactive input")
                .unwrap_err(),
            Err::<(), _>(io())
                .context("Failed parsing config")
                .unwrap_err(),
            Err::<(), _>(io())
                .context("Failed generating codegen files")
                .context("Failed running codegen")
                .unwrap_err(),
            Err::<(), _>(anyhow!("pnpm install exited with code 1"))
                .context("Failed installing project dependencies")
                .unwrap_err(),
            Err::<(), _>(io())
                .context("Failed reading directory entry")
                .unwrap_err(),
            anyhow!("Chain 42 is not configured"),
        ];
        assert_eq!(
            cases.iter().map(classify).collect::<Vec<_>>(),
            vec![
                (Outcome::Cancelled, ErrorClass::Other),
                (Outcome::Failure, ErrorClass::Config),
                (Outcome::Failure, ErrorClass::Codegen),
                (Outcome::Failure, ErrorClass::PackageManager),
                (Outcome::Failure, ErrorClass::Io),
                (Outcome::Failure, ErrorClass::Other),
            ]
        );
    }
}
