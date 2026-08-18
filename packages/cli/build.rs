extern crate napi_build;

fn main() {
    // `include_dir!` embeds the template tree without telling Cargo what it
    // read, so a new or edited template file otherwise leaves the previous
    // binary in place and `envio init` writes a project missing that file.
    println!("cargo:rerun-if-changed=templates");
    napi_build::setup();
}
