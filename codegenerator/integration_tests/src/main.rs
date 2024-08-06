mod hypersync_health;
use envio::{
    clap_definitions::{self, InitArgs, InitFlow, ProjectPaths},
    constants::project_paths::{DEFAULT_CONFIG_PATH, DEFAULT_GENERATED_PATH},
    executor::init::run_init_args,
    init_config::{self, Language},
};
use std::{fs, io, path::Path, time::Duration};
use strum::IntoEnumIterator;
use tokio::time::timeout;

fn delete_contents_of_folder<P: AsRef<std::path::Path>>(path: P) -> io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

fn clear_path_if_it_exists(path_str: &str) -> io::Result<()> {
    let path = Path::new(path_str);

    // Now you can use various methods provided by the Path type
    if path.exists() {
        delete_contents_of_folder(path_str)
    } else {
        Ok(())
    }
}

struct InitCombo {
    id: String,
    language: Language,
    init_args: InitArgs,
}

impl InitCombo {
    fn new(id: String, l: Language, init_flow: InitFlow) -> Self {
        let init_args = InitArgs {
            language: Some(l.clone()),
            init_commands: Some(init_flow),
            name: Some("test".to_string()),
            api_token: Some("4dc856dd-b0ea-494f-b27e-017b8b6b7e07".to_string()),
        };
        InitCombo {
            id,
            language: l,
            init_args,
        }
    }

    fn get_dir(&self) -> String {
        format!("./integration_test_output/{}/{}", self.id, self.language)
    }

    fn get_project_paths(&self) -> ProjectPaths {
        ProjectPaths {
            directory: Some(self.get_dir()),
            output_directory: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}

fn generate_init_args_combinations() -> Vec<InitCombo> {
    Language::iter()
        .flat_map(|l| {
            init_config::evm::Template::iter()
                .map(|t| {
                    InitCombo::new(
                        format!("evm_{t}"),
                        l.clone(),
                        InitFlow::Template(clap_definitions::evm::TemplateArgs {
                            template: Some(t.clone()),
                        }),
                    )
                })
                .chain(init_config::fuel::Template::iter().map(|t| {
                    InitCombo::new(
                        format!("fuel_{t}"),
                        l.clone(),
                        InitFlow::Fuel {
                            init_flow: Some(clap_definitions::fuel::InitFlow::Template(
                                clap_definitions::fuel::TemplateArgs {
                                    template: Some(t.clone()),
                                },
                            )),
                        },
                    )
                }))
                .collect::<Vec<_>>()
        })
        .collect()
}

async fn run_all_init_combinations() {
    let combinations = generate_init_args_combinations();

    for combo in combinations {
        let dir = combo.get_dir();
        let project_paths = combo.get_project_paths();
        let init_args = combo.init_args;
        //spawn a thread for fetching schema
        clear_path_if_it_exists(&dir).expect("unable to clear directories");
        println!("Running with init args: {:?}", init_args);

        //5 minute timeout
        let timeout_duration: Duration = Duration::from_secs(60);

        match timeout(
            timeout_duration,
            run_init_args(init_args.clone(), &project_paths),
        )
        .await
        {
            Err(e) => panic!(
                "Timed out after elapsed {} on running init args: {:?}",
                e, init_args
            ),
            Ok(res) => match res {
                Err(e) => {
                    panic!(
                        "Failed to run with init args: {:?}, due to error: {:?}",
                        init_args, e
                    )
                }
                Ok(()) => {
                    println!("Finished for combination: {:?}", init_args);
                }
            },
        };
    }
}

#[tokio::main]
async fn main() {
    run_all_init_combinations().await;
}

// This slows down all the integration tests, so we don't run it by default.
// #[cfg(test)]
// mod test {
//     use crate::run_all_init_combinations;

//     #[tokio::test(flavor = "multi_thread")]
//     async fn test_all_init_combinations() {
//         run_all_init_combinations().await;
//     }
// }
