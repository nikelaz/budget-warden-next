use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=data/budget-warden.gresource.xml");
    println!(
        "cargo:rerun-if-changed=data/icons/hicolor/scalable/apps/com.lazarovco.BudgetWarden.svg"
    );
    let target = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output directory"))
        .join("budget-warden.gresource");
    let output = Command::new("glib-compile-resources")
        .arg("data/budget-warden.gresource.xml")
        .arg("--sourcedir=data")
        .arg("--target")
        .arg(target)
        .output()
        .expect("glib-compile-resources is required to embed application icons");
    assert!(
        output.status.success(),
        "Resource compilation failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
