use std::error::Error;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use handlebars::Handlebars;

use serde::Serialize;

fn main() {
    copy_directory("templates/static", "../generated").unwrap();
    match generate_types() {
        Err(e) => println!("Error: {}", e),
        Ok(()) => (),
    };
    // write_static_files_to_generated().unwrap();
    // write_to_file_in_generated("test.txt", content).unwrap();
    println!("installing packages... ");

    Command::new("pnpm")
        .arg("install")
        .current_dir("../generated")
        .spawn()
        .unwrap();

    print!("building code");

    Command::new("pnpm")
        .arg("build")
        .current_dir("../generated")
        .spawn()
        .unwrap();
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
}

fn generate_types() -> Result<(), Box<dyn Error>> {
    let mut handlebars = Handlebars::new();
    handlebars.set_strict_mode(true);
    // let source = fs::read_to_string("templates/dynamic/src/Types.res")?;

    handlebars.register_template_file("Types.res", "templates/dynamic/src/Types.res")?;

    let event1 = EventType {
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
    };

    let event2 = EventType {
        name_lower_camel: String::from("updateGravatar"),
        name_upper_camel: String::from("UpdateGravatar"),
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
    };

    let types_data = TypesTemplate {
        events: vec![event1, event2],
    };

    let rendered_string = handlebars.render("Types.res", &types_data)?;

    println!("{}", rendered_string);

    write_to_file_in_generated("src/Types.res", &rendered_string)?;
    Ok(())
}

fn write_to_file_in_generated(filename: &str, content: &str) -> std::io::Result<()> {
    let gen_dir_path = "../generated";
    fs::create_dir_all(gen_dir_path)?;
    fs::write(format! {"{}/{}", gen_dir_path, filename}, content)
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
