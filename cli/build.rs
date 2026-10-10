use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(
        std::env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets CARGO_MANIFEST_DIR"),
    );
    let core_manifest = manifest_dir.join("../core/Cargo.toml");
    println!("cargo:rerun-if-changed={}", core_manifest.display());
    let contents = fs::read_to_string(&core_manifest).expect("read sibling bw_core manifest");
    let mut in_package = false;
    let version = contents
        .lines()
        .find_map(|line| {
            let line = line.trim();
            if line.starts_with('[') {
                in_package = line == "[package]";
                return None;
            }
            if in_package {
                line.strip_prefix("version = ")
                    .map(|value| value.trim_matches('"').to_string())
            } else {
                None
            }
        })
        .expect("bw_core package version");
    println!("cargo:rustc-env=BW_CORE_VERSION={version}");
}
