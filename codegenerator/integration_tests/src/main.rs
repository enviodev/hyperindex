use envio::cli_args::constants::{DEFAULT_CONFIG_PATH, DEFAULT_GENERATED_PATH};
use envio::cli_args::{InitArgs, InitFlow, Language, ProjectPaths, Template, TemplateArgs};
use envio::utils::run_init_args;
use std::time::Duration;
use strum::IntoEnumIterator;
use tokio::task::JoinSet;
use tokio::time::timeout;

use std::fs;
use std::io;
use std::path::Path;

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

struct TemplateLangCombo {
    language: Language,
    template: Template,
    init_args: InitArgs,
}

impl TemplateLangCombo {
    fn new(l: Language, t: Template) -> Self {
        let init_args = InitArgs {
            language: Some(l.clone()),
            init_commands: Some(InitFlow::Template(TemplateArgs {
                template: Some(t.clone()),
            })),
            name: Some("test".to_string()),
        };
        TemplateLangCombo {
            language: l,
            template: t,
            init_args,
        }
    }

    fn get_dir(&self) -> String {
        format!(
            "./integration_test_output/{}/{}",
            self.template, self.language
        )
    }

    fn get_project_paths(&self) -> ProjectPaths {
        ProjectPaths {
            directory: Some(self.get_dir()),
            output_directory: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}

fn generate_init_args_combinations() -> Vec<TemplateLangCombo> {
    Language::iter()
        .flat_map(|l| {
            Template::iter()
                .map(|t| TemplateLangCombo::new(l.clone(), t.clone()))
                .collect::<Vec<_>>()
        })
        .collect()
}

async fn run_all_init_combinations() {
    let combinations = generate_init_args_combinations();

    let mut join_set = JoinSet::new();

    for combo in combinations {
        let dir = combo.get_dir();
        let project_paths = combo.get_project_paths();
        let init_args = combo.init_args;
        //spawn a thread for fetching schema
        join_set.spawn(async move {
            clear_path_if_it_exists(&dir).expect("unable to clear directories");
            println!("Running with init args: {:?}", init_args);

            //5 minute timeout
            let timeout_duration: Duration = Duration::from_secs(5 * 60);

            match timeout(timeout_duration, run_init_args(&init_args, &project_paths)).await {
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
        });
    }

    //Await all the envio init and write threads before finishing
    while let Some(join) = join_set.join_next().await {
        if join.is_err() {
            join_set.shutdown().await;
            join.unwrap();
            assert!(false);
        }
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
