use serde::Serialize;

#[derive(Serialize)]
pub struct CapitalizedOptions {
    capitalized: String,
    uncapitalized: String,
}

pub trait Capitalize {
    fn capitalize(&self) -> String;

    fn uncapitalize(&self) -> String;

    fn to_capitalized_options(&self) -> CapitalizedOptions;
}

impl Capitalize for String {
    fn capitalize(&self) -> String {
        let mut chars = self.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        }
    }
    fn uncapitalize(&self) -> String {
        let mut chars = self.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first.to_lowercase().collect::<String>() + chars.as_str(),
        }
    }

    fn to_capitalized_options(&self) -> CapitalizedOptions {
        let capitalized = self.capitalize();
        let uncapitalized = self.uncapitalize();

        CapitalizedOptions {
            capitalized,
            uncapitalized,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Capitalize;
    #[test]
    fn string_capitalize() {
        let string = String::from("hello");
        let capitalized = string.capitalize();
        assert_eq!(capitalized, "Hello");
    }

    #[test]
    fn string_uncapitalize() {
        let string = String::from("Hello");
        let uncapitalized = string.uncapitalize();
        assert_eq!(uncapitalized, "hello");
    }

    #[test]
    fn string_to_capitalization_options() {
        let string = String::from("Hello");
        let capitalization_options = string.to_capitalized_options();
        assert_eq!(capitalization_options.uncapitalized, "hello");
        assert_eq!(capitalization_options.capitalized, "Hello");
    }
}
