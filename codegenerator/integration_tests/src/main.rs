use envio::cli_args::{InitArgs, Language, Template};
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

fn create_and_push_init_args(
    combinations: &mut Vec<InitArgs>,
    language: &Language,
    template: &Template,
) {
    let init_args = InitArgs {
        language: Some(language.clone()),
        template: Some(template.clone()),
        directory: Some(format!(
            "./integration_test_output/{}/{}",
            template, language
        )),
        name: Some("test".to_string()),
        subgraph_migration: None, // ...
    };
    combinations.push(init_args);
}

fn generate_init_args_combinations() -> Vec<InitArgs> {
    let mut combinations: Vec<InitArgs> = Vec::new();

    // Use nested loops or iterators to generate all possible combinations of InitArgs.
    for language in Language::iter() {
        for template in Template::iter() {
            create_and_push_init_args(&mut combinations, &language, &template);
        }
    }

    // NOTE: you can use the below code to test a specific scenario in isolation.
    // create_and_push_init_args(&mut combinations, &Language::Rescript, &Template::Blank);

    combinations
}

async fn run_all_init_combinations() {
    let combinations = generate_init_args_combinations();

    let mut join_set = JoinSet::new();

    for init_args in combinations {
        //spawn a thread for fetching schema
        join_set.spawn(async move {
            let dir = init_args
                .directory
                .as_ref()
                // Here we panic if it is None, because we need this for the tests.
                .expect("Directory is None!");
            clear_path_if_it_exists(&dir).expect("unable to clear directories");
            println!("Running with init args: {:?}", init_args);

            //5 minute timeout
            let timeout_duration: Duration = Duration::from_secs(5 * 60);

            match timeout(timeout_duration, run_init_args(&init_args)).await {
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
    println!("main");
    run_all_init_combinations().await;
}

#[cfg(test)]
mod test {
    use crate::run_all_init_combinations;

    #[tokio::test(flavor = "multi_thread")]
    async fn test_all_init_combinations() {
        run_all_init_combinations().await;
    }
}
