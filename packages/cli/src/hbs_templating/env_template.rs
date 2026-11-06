use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
};

pub fn write(path: impl AsRef<Path>, token: &Option<String>) -> io::Result<()> {
    let path = path.as_ref();
    match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => file.write_all(render(token).as_bytes()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let Some(token) = token else { return Ok(()) };
            let values = crate::utils::dotenv::from_path(path).map_err(io::Error::other)?;
            if values
                .get("ENVIO_API_TOKEN")
                .is_some_and(|value| !value.is_empty() || token.is_empty())
            {
                return Ok(());
            }
            let existing = fs::read_to_string(path)?;
            let mut file = OpenOptions::new().append(true).open(path)?;
            if !existing.is_empty() && !existing.ends_with('\n') {
                writeln!(file)?;
            }
            writeln!(file, "ENVIO_API_TOKEN=\"{token}\"")
        }
        Err(error) => Err(error),
    }
}

/// Renders the `.env` file scaffolded by both `envio init` and contract import.
pub fn render(envio_api_token: &Option<String>) -> String {
    let mut out =
        String::from("# To create or update a token visit https://envio.dev/app/api-tokens\n");
    match envio_api_token {
        Some(token) => out.push_str(&format!("ENVIO_API_TOKEN=\"{token}\"\n")),
        None => {
            out.push_str("# Uncomment the line below and set a valid token\n");
            out.push_str("# ENVIO_API_TOKEN=\"<YOUR-API-TOKEN>\"\n");
        }
    }
    out
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn renders_with_token() {
        insta::assert_snapshot!(render(&Some("abc123".to_string())));
    }

    #[test]
    fn renders_without_token() {
        insta::assert_snapshot!(render(&None));
    }
}
