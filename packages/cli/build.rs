fn main() {
    // Forward ENVIO_VERSION to the binary at compile time.
    // CI sets this env var; locally it falls back to Cargo.toml version.
    println!("cargo:rerun-if-env-changed=ENVIO_VERSION");
    if let Ok(v) = std::env::var("ENVIO_VERSION") {
        println!("cargo:rustc-env=ENVIO_VERSION={v}");
    }
}
