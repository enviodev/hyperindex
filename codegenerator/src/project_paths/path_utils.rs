use std::path::{Component, PathBuf};

pub fn normalize_path(path: &PathBuf) -> PathBuf {
    let mut components = path.components().peekable();

    let mut normalized_path_buf = match components.clone().peek() {
        Some(c @ Component::Prefix(..)) => {
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
            Component::Prefix(..) => unreachable!("Windows Prefix not handled"),
            Component::RootDir => {
                normalized_path_buf.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                normalized_path_buf.pop();
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
    #[test]
    fn normalize_path_1() {
        let unnormalized_path = PathBuf::from("my_dir/another_dir/../my_file.js");
        let normalized_path = normalize_path(&unnormalized_path);
        let expected_normalized_path = PathBuf::from("my_dir/my_file.js");
        assert_eq!(normalized_path, expected_normalized_path);
    }

    #[test]
    fn normalize_path_2() {
        let unnormalized_path = PathBuf::from("my_dir/another_dir/../../my_file.js");
        let normalized_path = normalize_path(&unnormalized_path);
        let expected_normalized_path = PathBuf::from("my_file.js");
        assert_eq!(normalized_path, expected_normalized_path);
    }

    #[test]
    fn normalize_path_start_with_parent() {
        let unnormalized_path = PathBuf::from("../my_dir/another_dir/../my_file.js");
        let normalized_path = normalize_path(&unnormalized_path);
        let expected_normalized_path = PathBuf::from("../my_dir/my_file.js");
        assert_eq!(normalized_path, expected_normalized_path);
    }
}
