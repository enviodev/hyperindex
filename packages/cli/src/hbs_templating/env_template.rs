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
