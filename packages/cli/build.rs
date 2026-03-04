fn main() {
    // Sets platform-specific linker flags for the napi cdylib:
    // - macOS: -undefined dynamic_lookup (required for Node.js symbol resolution)
    // - Linux GNU: -Wl,-z,nodelete (prevents DSO unloading issues with glibc)
    napi_build::setup();
}
