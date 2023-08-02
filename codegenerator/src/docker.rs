use std::io::Error;
use std::process::Command;

pub const CONTAINER_NAME_HASURA: &str = "generated-graphql-engine-1";
pub const CONTAINER_NAME_POSTGRES: &str = "generated-envio-postgres-1";

pub fn is_container_running(container_name: &str) -> Result<bool, IOError> {
    let output = Command::new("docker")
        .arg("ps")
        .arg("--format")
        .arg("{{.Names}}")
        .output()?;

    if output.status.success() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        let running_containers: Vec<&str> = output_str.lines().collect();
        Ok(running_containers.contains(&container_name))
    } else {
        Err(IOError::from_raw_os_error(
            output.status.code().unwrap_or(1),
        ))
    }
}

pub fn testing(container_name: &str) {
    match is_container_running(container_name) {
        Ok(true) => println!("Container '{}' is running.", container_name),
        Ok(false) => println!("Container '{}' is not running.", container_name),
        Err(e) => println!("Error: {}", e),
    }
}
