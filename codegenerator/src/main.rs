use std::error::Error;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use handlebars::Handlebars;

use serde::{Deserialize, Serialize};
use serde_yaml;

use ethereum_abi::Abi;

#[derive(Debug, Serialize, Deserialize)]
struct Network {
    id: i32,
    rpc_url: String,
    start_block: i32,
}

#[derive(Debug, Serialize, Deserialize)]
struct Contract {
    name: String,
    abi: String,
    address: String,
    events: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Config {
    version: String,
    description: String,
    repository: String,
    networks: Vec<Network>,
    handler: String,
    contracts: Vec<Contract>,
}

const CODE_GEN_PATH: &str = "../scenarios/test_codegen/generated";
const CURRENT_DIR_PATH: &str = "../scenarios/test_codegen";

fn main() {
    let config_dir = format!("{}/{}", CURRENT_DIR_PATH, "config.yaml");

    let config = std::fs::read_to_string(&config_dir).unwrap();

    let deserialized_yaml: Config = serde_yaml::from_str(&config).unwrap();
    // Generate the type-safe contract bindings by providing the ABI
    // definition in human readable format
    // abigen!(
    //     IUniswapV2Pair,
    //     r#"[
    //         function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    //     ]"#,
    // );
    // for contract in deserialized_yaml.contracts.iter() {
    //     // let test = ethers_rs::from_abi(&contract.abi.try_into( ff).unwrap());
    //     let test = ethers::contract::abigen!(Gravitar, r#"[event NewGravatar(uint256 id,address owner,string displayName,string imageUrl)]"#)

    //     for abi in contract.abi.iter() {
    //         let _ = parse_event_signature(abi);
    //     }
    // }

    copy_directory("templates/static", CODE_GEN_PATH).unwrap();

    let mut event_types: Vec<RecordType> = Vec::new(); //parse_event_signature(abi);

    for contract in deserialized_yaml.contracts.iter() {
        let abi_path = format!("{}/{}", CURRENT_DIR_PATH, contract.abi);
        let abi_file = std::fs::read_to_string(abi_path).unwrap();
        let contract_abi: Abi = serde_json::from_str(&abi_file).expect("failed to parse abi");
        let events: Vec<ethereum_abi::Event> = contract_abi.events;
        for event_name in contract.events.iter() {
            println!("{event_name}");
            let event = events.iter().find(|&event| &event.name == event_name);

            match event {
                Some(event) => {
                    let event_type = RecordType {
                        name: event.name.to_owned().to_capitalized_options(),
                        params: event
                            .inputs
                            .iter()
                            .map(|input| ParamType {
                                key: input.name.to_owned(),
                                type_: match input.type_ {
                                    ethereum_abi::Type::Uint(_size) => "int",
                                    ethereum_abi::Type::Int(_size) => "int",
                                    ethereum_abi::Type::Bool => "bool",
                                    ethereum_abi::Type::Address => "string",
                                    ethereum_abi::Type::Bytes => "string",
                                    ethereum_abi::Type::String => "string",
                                    ethereum_abi::Type::FixedBytes(_) => "type_not_handled",
                                    ethereum_abi::Type::Array(_) => "type_not_handled",
                                    ethereum_abi::Type::FixedArray(_, _) => "type_not_handled",
                                    ethereum_abi::Type::Tuple(_) => "type_not_handled",
                                }
                                .to_owned(),
                            })
                            .collect(),
                    };
                    event_types.push(event_type);
                }
                None => (),
            };
        }
    }

    // let test = Abi::from_reader(abi_str);
    match generate_types(event_types) {
        Err(e) => println!("Error: {}", e),
        Ok(()) => (),
    };
    // write_static_files_to_generated().unwrap();
    // write_to_file_in_generated("test.txt", content).unwrap();
    println!("installing packages... ");

    Command::new("pnpm")
        .arg("install")
        .current_dir(CODE_GEN_PATH)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();

    print!("formatting code");

    Command::new("pnpm")
        .arg("rescript")
        .arg("format")
        .arg("-all")
        .current_dir(CODE_GEN_PATH)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();

    print!("building code");

    Command::new("pnpm")
        .arg("build")
        .current_dir(CODE_GEN_PATH)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
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

fn parse_event_signature(event_signature: &str) -> RecordType {
    //"event NewGravatar(uint256 id,address owner,string displayName,string imageUrl)"
    // trim and remove `event`
    // get event name as first word up until first bracket
    // get the substring between brackets and split by commas
    // convert into rescript types

    // let test = ethers_rs::from_abi(event_signature);
    println!("{}", event_signature);

    RecordType {
        name: String::from("NewGravatar").to_capitalized_options(),
        params: vec![
            ParamType {
                key: String::from("id"),
                type_: String::from("string"),
            },
            ParamType {
                key: String::from("owner"),
                type_: String::from("string"),
            },
            ParamType {
                key: String::from("displayName"),
                type_: String::from("string"),
            },
            ParamType {
                key: String::from("imageUrl"),
                type_: String::from("string"),
            },
        ],
    }
}

#[derive(Serialize)]
struct ParamType {
    key: String,
    type_: String,
}

#[derive(Serialize)]
struct RecordType {
    name: CapitalizedOptions,
    params: Vec<ParamType>,
}

#[derive(Serialize)]
struct TypesTemplate {
    events: Vec<RecordType>,
    entities: Vec<RecordType>,
}

fn generate_types(event_types: Vec<RecordType>) -> Result<(), Box<dyn Error>> {
    // let source = fs::read_to_string("templates/dynamic/src/Types.res")?;

    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);

    handlebars.register_template_file("Types.res", "templates/dynamic/src/Types.res")?;

    let types_data = TypesTemplate {
        events: event_types,
        entities: vec![RecordType {
            name: String::from("gravatar").to_capitalized_options(),
            params: vec![
                ParamType {
                    key: String::from("id"),
                    type_: String::from("string"),
                },
                ParamType {
                    key: String::from("owner"),
                    type_: String::from("string"),
                },
                ParamType {
                    key: String::from("displayName"),
                    type_: String::from("string"),
                },
                ParamType {
                    key: String::from("imageUrl"),
                    type_: String::from("string"),
                },
                ParamType {
                    key: String::from("updatesCount"),
                    type_: String::from("int"),
                },
            ],
        }],
    };

    let rendered_string = handlebars.render("Types.res", &types_data)?;

    println!("{}", rendered_string);

    write_to_file_in_generated("src/Types.res", &rendered_string)?;
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
