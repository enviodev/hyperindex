use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use handlebars::Handlebars;

use serde::Serialize;

mod entity_parsing;

mod event_parsing;

const CODE_GEN_PATH: &str = "../scenarios/test_codegen/generated";
const CURRENT_DIR_PATH: &str = "../scenarios/test_codegen";

fn main() -> Result<(), Box<dyn Error>> {
    copy_directory("templates/static", CODE_GEN_PATH)?;

    let contract_types = event_parsing::get_contract_types_from_config()?;
    let entity_types = entity_parsing::get_entity_record_types_from_schema()?;

    generate_types(contract_types, entity_types)?;

    println!("installing packages... ");

    Command::new("pnpm")
        .arg("install")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    print!("formatting code");

    Command::new("pnpm")
        .arg("rescript")
        .arg("format")
        .arg("-all")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    print!("building code");

    Command::new("pnpm")
        .arg("build")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    Ok(())
}

#[derive(Serialize)]
struct CapitalizedOptions {
    capitalized: String,
    uncapitalized: String,
}

trait Capitalize {
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

#[derive(Serialize)]
struct ParamType {
    key: String,
    type_: String,
}

#[derive(Serialize)]
pub struct RecordType {
    name: CapitalizedOptions,
    params: Vec<ParamType>,
}
#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    address: String,
    events: Vec<RecordType>,
}
#[derive(Serialize)]
struct TypesTemplate {
    contracts: Vec<Contract>,
    entities: Vec<RecordType>,
}

fn generate_types(
    contracts: Vec<Contract>,
    entity_types: Vec<RecordType>,
) -> Result<(), Box<dyn Error>> {
    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);
    handlebars.register_escape_fn(handlebars::no_escape);

    handlebars.register_template_file("Types.res", "templates/dynamic/src/Types.res")?;
    handlebars.register_template_file("Handlers.res", "templates/dynamic/src/Handlers.res")?;
    handlebars.register_template_file(
        "EventProcessing.res",
        "templates/dynamic/src/EventProcessing.res",
    )?;

    let types_data = TypesTemplate {
        contracts,
        entities: entity_types,
    };

    let rendered_string_types = handlebars.render("Types.res", &types_data)?;
    let rendered_string_handlers = handlebars.render("Handlers.res", &types_data)?;
    let rendered_string_event_processing = handlebars.render("EventProcessing.res", &types_data)?;

    write_to_file_in_generated("src/Types.res", &rendered_string_types)?;
    write_to_file_in_generated("src/Handlers.res", &rendered_string_handlers)?;
    write_to_file_in_generated("src/EventProcessing.res", &rendered_string_event_processing)?;
    Ok(())
}

fn write_to_file_in_generated(filename: &str, content: &str) -> std::io::Result<()> {
    fs::create_dir_all(CODE_GEN_PATH)?;
    fs::write(format! {"{}/{}", CODE_GEN_PATH, filename}, content)
}

pub fn copy_directory<U: AsRef<Path>, V: AsRef<Path>>(
    from: U,
    to: V,
) -> Result<(), std::io::Error> {
    let mut stack = Vec::new();
    stack.push(PathBuf::from(from.as_ref()));

    let output_root = PathBuf::from(to.as_ref());
    let input_root = PathBuf::from(from.as_ref()).components().count();

    while let Some(working_path) = stack.pop() {
        println!("process: {:?}", &working_path);

        // Generate a relative path
        let src: PathBuf = working_path.components().skip(input_root).collect();

        // Create a destination if missing
        let dest = if src.components().count() == 0 {
            output_root.clone()
        } else {
            output_root.join(&src)
        };
        if fs::metadata(&dest).is_err() {
            println!(" mkdir: {:?}", dest);
            fs::create_dir_all(&dest)?;
        }

        for entry in fs::read_dir(working_path)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                match path.file_name() {
                    Some(filename) => {
                        let dest_path = dest.join(filename);
                        println!("  copy: {:?} -> {:?}", &path, &dest_path);
                        fs::copy(&path, &dest_path)?;
                    }
                    None => {
                        println!("failed: {:?}", path);
                    }
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::Capitalize;
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
