use envio::run_init_args;

fn main () {
    println!("main");
}

#[cfg(test)]
mod test {
    use super::*;
    use strum::IntoEnumIterator;
    use tempfile::tempdir;
    use tokio::task::JoinSet;

    fn generate_init_args_combinations() -> Vec<InitArgs> {
        let mut combinations = Vec::new();

        // Use nested loops or iterators to generate all possible combinations of InitArgs.

        for language in Language::iter() {
            for template in Template::iter() {
                let init_args = InitArgs {
                    // Set other fields here
                    language: Some(language.clone()),
                    template: Some(template.clone()),
                    directory: None,
                    name: Some("test".to_string()),
                    subgraph_migration: None, // ...
                };

                combinations.push(init_args);
            }
        }

        combinations
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn test_all_init_combinations() {
        let combinations = generate_init_args_combinations();

        let mut join_set = JoinSet::new();

        for mut init_args in combinations {
            //spawn a thread for fetching schema
            join_set.spawn(async move {
                let temp_dir = tempdir().unwrap();
                init_args.directory = Some(temp_dir.path().to_str().unwrap().to_string());
                println!("Running with init args: {:?}", init_args);

                match run_init_args(&init_args).await {
                    Err(_) => {
                        println!("Failed to run with init args: {:?}", init_args);
                        temp_dir.close().unwrap();
                        panic!("Failed to run with init args: {:?}", init_args)
                    }
                    Ok(_) => {
                        println!("Finished for combination: {:?}", init_args);
                        temp_dir.close().unwrap();
                    }
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
