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

    let mut event_types: Vec<EventType> = Vec::new(); //parse_event_signature(abi);

    for contract in deserialized_yaml.contracts.iter() {
        let contract_abi: Abi = serde_json::from_str(&contract.abi).expect("failed to parse abi");
        let events: Vec<ethereum_abi::Event> = contract_abi.events;
        for event_name in contract.events.iter() {
            let event = events.iter().find(|&event| &event.name == event_name);

            match event {
                Some(event) => {
                    let event_type = EventType {
                        name_lower_camel: event.name,
                        name_upper_camel: event.name,
                        params: event
                            .inputs
                            .iter()
                            .map(|&input| EventTypeParam {
                                key_string: input.name,
                                type_string: match input.type_ {
                                    ethereum_abi::Type::Uint(size) => "int",
                                    ethereum_abi::Type::Int(size) => "int",
                                    ethereum_abi::Type::Bool => "bool",
                                    ethereum_abi::Type::Address => "string",
                                    ethereum_abi::Type::Bytes => "string",
                                    _ => "other",
                                }
                                .to_owned(),
                            })
                            .collect(),
                    };
                }
                None => (),
            }

            // event_types.push(parse_event_signature(abi));
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
    //
    print!("building code");

    Command::new("pnpm")
        .arg("build")
        .current_dir(CODE_GEN_PATH)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
}

fn parse_event_signature(event_signature: &str) -> EventType {
    //"event NewGravatar(uint256 id,address owner,string displayName,string imageUrl)"
    // trim and remove `event`
    // get event name as first word up until first bracket
    // get the substring between brackets and split by commas
    // convert into rescript types

    // let test = ethers_rs::from_abi(event_signature);
    println!("{}", event_signature);

    EventType {
        name_lower_camel: String::from("newGravatar"),
        name_upper_camel: String::from("NewGravatar"),
        params: vec![
            EventTypeParam {
                key_string: String::from("id"),
                type_string: String::from("string"),
            },
            EventTypeParam {
                key_string: String::from("owner"),
                type_string: String::from("string"),
            },
            EventTypeParam {
                key_string: String::from("displayName"),
                type_string: String::from("string"),
            },
            EventTypeParam {
                key_string: String::from("imageUrl"),
                type_string: String::from("string"),
            },
        ],
    }
}

#[derive(Serialize)]
struct EventTypeParam {
    key_string: String,
    type_string: String,
}

#[derive(Serialize)]
struct EventType {
    name_lower_camel: String,
    name_upper_camel: String,
    params: Vec<EventTypeParam>,
}

#[derive(Serialize)]
struct TypesTemplate {
    events: Vec<EventType>,
    entities: Vec<EventType>,
}

fn generate_types(event_types: Vec<EventType>) -> Result<(), Box<dyn Error>> {
    // let source = fs::read_to_string("templates/dynamic/src/Types.res")?;

    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);

    handlebars.register_template_file("Types.res", "templates/dynamic/src/Types.res")?;

    let types_data = TypesTemplate {
        events: event_types,
        entities: vec![EventType {
            name_lower_camel: String::from("gravatar"),
            name_upper_camel: String::from("Gravatar"),
            params: vec![
                EventTypeParam {
                    key_string: String::from("id"),
                    type_string: String::from("string"),
                },
                EventTypeParam {
                    key_string: String::from("owner"),
                    type_string: String::from("string"),
                },
                EventTypeParam {
                    key_string: String::from("displayName"),
                    type_string: String::from("string"),
                },
                EventTypeParam {
                    key_string: String::from("imageUrl"),
                    type_string: String::from("string"),
                },
                EventTypeParam {
                    key_string: String::from("updatesCount"),
                    type_string: String::from("int"),
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
