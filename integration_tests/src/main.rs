use envio::utils::run_init_args;

fn main() {
    println!("main");
}

#[cfg(test)]
mod test {
    use super::*;
    use envio::cli_args::{InitArgs, Language, Template};
    use strum::IntoEnumIterator;
    use tokio::task::JoinSet;
    use tokio::time::timeout;

    use std::fs;
    use std::io;
    use std::path::Path;
    use std::time::Duration;

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

    fn generate_init_args_combinations() -> Vec<InitArgs> {
        let mut combinations: Vec<InitArgs> = Vec::new();

        // Use nested loops or iterators to generate all possible combinations of InitArgs.

        for language in Language::iter() {
            for template in Template::iter() {
                let init_args = InitArgs {
                    // Set other fields here
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
        }

        // NOTE: you can use the below code to test a specific scenario in isolation.
        // TODO: Work out why the Erc20 fails, but still passes the test. https://github.com/Float-Capital/indexer/issues/676
        // let mut combinations: Vec<InitArgs> = Vec::new();
        // let one_to_test = InitArgs {
        //     directory: Some(String::from("./integration_test_output/Erc20/Rescript")),
        //     name: Some(String::from("test")),
        //     template: Some(Template::Erc20),
        //     subgraph_migration: None,
        //     language: Some(Language::Rescript),
        // };
        // combinations.push(one_to_test);
        combinations
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn test_all_init_combinations() {
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
}
