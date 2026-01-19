use std::path::{Component, PathBuf};

use anyhow::anyhow;
use itertools::Itertools;

use super::ParsedProjectPaths;

//Used for getting the path relative current dir for paths referenced in config.yaml
//eg. current path is root_path/, config_path is root_path/config.yaml
//handler in config.yaml is defined as ./EventHandler.js
//return value should be root_path/EventHandler.js
pub fn get_config_path_relative_to_root(
    project_paths: &ParsedProjectPaths,
    relative_config_path: PathBuf,
) -> anyhow::Result<PathBuf> {
    let config_directory = project_paths.config.parent().ok_or_else(|| {
        anyhow!(
            "Unexpected config file should have a parent directory {}, {}",
            project_paths.config.to_str().unwrap(),
            relative_config_path.to_str().unwrap()
        )
    })?;

    let path_relative = relative_config_path;
    let path_joined = config_directory.join(path_relative);
    let path = normalize_path(path_joined);

    Ok(path)
}

pub fn normalize_path(path: PathBuf) -> PathBuf {
    let mut components = path.components().peekable();

    let mut normalized_path_buf = match components.clone().peek() {
        Some(c @ Component::Prefix(_)) => {
            components.next();
            PathBuf::from(c.as_os_str())
        }
        Some(Component::ParentDir) => {
            components.next();
            PathBuf::from("../")
        }
        _ => PathBuf::new(),
    };

    for component in components {
        match component {
            Component::Prefix(_) => unreachable!("Windows Prefix not handled"),
            Component::RootDir => {
                normalized_path_buf.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                // Running through the components like this involves some
                // allocations, but this is not a performance sensitive part of
                // the code generator.
                if normalized_path_buf
                    .components()
                    .all(|c| c == Component::ParentDir)
                {
                    // Step further up parent directories
                    normalized_path_buf.push(PathBuf::from("../"));
                } else {
                    // Still in a child directly, come back out of it
                    if !normalized_path_buf.pop() {
                        panic!("Trying to descend below the root directory")
                    }
                }
            }
            Component::Normal(c) => {
                normalized_path_buf.push(c);
            }
        }
    }
    normalized_path_buf
}

/// Add ./ to a path if its not already represented as a relative path
/// Panics if window "prefix" is used
pub fn add_leading_relative_dot(path: PathBuf) -> PathBuf {
    match path.components().next() {
        Some(component) => match component {
            Component::ParentDir | Component::CurDir => path,
            Component::Normal(_) => PathBuf::from(".").join(path),
            Component::RootDir => path,
            Component::Prefix(_) => unreachable!("Windows Prefix path component unreachable"),
        },
        None => PathBuf::from("."),
    }
}

/// Add /. to the end of a path if its not already ending in /.
pub fn add_trailing_relative_dot(path: PathBuf) -> PathBuf {
    //Note components doesn't pick up on trailing CurDir, so always add it on and return
    let components = [path.components().collect_vec(), vec![Component::CurDir]].concat();
    PathBuf::from_iter(components)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;
    // Good case for a syntax macro to shorten each test to a single line.
    macro_rules! test_path_function {
        ($func:expr; $($name:ident: $input:expr, $expected:expr,)*) => {
            $(
                paste::item! {
                #[test]
                fn [< test_path_ $name >]() {
                    let input = PathBuf::from($input);
                    let output = $func(input);
                    let expected = PathBuf::from($expected);
                    assert_eq!(expected.to_str(), output.to_str());
                }
                }
            )*
        };
    }

    test_path_function!(normalize_path;
        backtrack:                     "my_dir/another_dir/../my_file.js",             "my_dir/my_file.js",
        backtrack_twice:               "my_dir/another_dir/../../my_file.js",          "my_file.js",
        backtrack_to_parent:           "my_dir/another_dir/../../../my_file.js",       "../my_file.js",
        backtrack_to_parents_parent:   "my_dir/../another_dir/../../../my_file.js",    "../../my_file.js",
        root:                          "/my_dir/another_dir/../../my_file.js",         "/my_file.js",
        start_with_parent:             "../my_dir/another_dir/../my_file.js",          "../my_dir/my_file.js",
    );

    #[test]
    #[should_panic]
    fn normalize_path_root_parent() {
        let unnormalized_path = PathBuf::from("/../my_file.js");
        normalize_path(unnormalized_path);
    }

    test_path_function!(add_leading_relative_dot;
        leading_test_dot_dot_slash_dot: "../.", "../.",
        leading_test_dot_dot: "..", "..",
        leading_test_generated:  "generated", "./generated",
        leading_test_dot_slash_generated:  "./generated", "./generated",
    );

    test_path_function!(add_trailing_relative_dot;
        trailing_generated: "generated", "generated/.",
        trailing_test_dot_dot_slash_dot: "../.", "../.",
        trailing_test_dot_slash_dir_slash_dot: "./dir/.", "./dir/.",
    );
}
