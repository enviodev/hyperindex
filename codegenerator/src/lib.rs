use project_paths::ProjectPaths;
use std::fs;
use std::path::Path;

pub mod config_parsing;
pub mod linked_hashmap;
pub mod project_paths;

pub mod capitalization;
pub mod cli_args;

pub mod hbs_templating;

#[cfg(unix)]
fn set_executable_permissions(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(&path)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions)?;
    Ok(())
}

#[cfg(windows)]
///Impossible to set an executable mode on windows
///This function is simply for the hasura script for now
///So we can add some manual wsl steps for windows users
fn set_executable_permissions(path: &Path) -> std::io::Result<()> {
    let mut permissions = fs::metadata(&path)?.permissions();
    permissions.set_readonly(false);
    fs::set_permissions(&path, permissions)?;

    Ok(())
}

fn make_file_executable(filename: &str, project_paths: &ProjectPaths) -> std::io::Result<()> {
    let file_path = &project_paths.generated.join(filename);

    set_executable_permissions(&file_path)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    #[test]
    fn wildcard_path_join() {
        let expected_string = "my_dir/*";
        let parent_path = PathBuf::from("my_dir");
        let wild_card_path = PathBuf::from("*");
        let joined = parent_path.join(wild_card_path);
        let joined_str = joined.to_str().unwrap();

        assert_eq!(expected_string, joined_str);
    }
}
