use std::path::{Component, Path, PathBuf};

pub fn normalize_path(path: &Path) -> PathBuf {
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
                if normalized_path_buf.components().all(|c| c == Component::ParentDir) {
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

#[cfg(test)]

mod tests {
    use super::normalize_path;
    use std::path::PathBuf;

    // Good case for a syntax macro to shorten each test to a single line.
    macro_rules! test_normalization {
        ($($name:ident: $input:expr, $expected:expr,)*) => {
            $(
                paste::item! {
                #[test]
                fn [< test_ $name >]() {
                    let unnormalized_path = PathBuf::from($input);
                    let normalized_path = normalize_path(&unnormalized_path);
                    let expected_normalized_path = PathBuf::from($expected);
                    assert_eq!(normalized_path, expected_normalized_path);
                }
                }
            )*
        };
    }

    test_normalization! {
        path_backtrack:                     "my_dir/another_dir/../my_file.js",             "my_dir/my_file.js",
        path_backtrack_twice:               "my_dir/another_dir/../../my_file.js",          "my_file.js",
        path_backtrack_to_parent:           "my_dir/another_dir/../../../my_file.js",       "../my_file.js",
        path_backtrack_to_parents_parent:   "my_dir/../another_dir/../../../my_file.js",    "../../my_file.js",
        path_root:                          "/my_dir/another_dir/../../my_file.js",         "/my_file.js",
        path_start_with_parent:             "../my_dir/another_dir/../my_file.js",          "../my_dir/my_file.js",
    }

    #[test]
    #[should_panic]
    fn normalize_path_root_parent() {
        let unnormalized_path = PathBuf::from("/../my_file.js");
        normalize_path(&unnormalized_path);
    }
}