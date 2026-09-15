//! Local linker shim.
//!
//! GPUI's Linux X11 backend links against `-lxkbcommon-x11`, but this machine
//! only ships the runtime library (`libxkbcommon-x11.so.0`) without the
//! development symlink (`libxkbcommon-x11.so`). Creating the symlink itself
//! would require root, so instead we link against a local alias and point the
//! linker at it. Remove this file once `libxkbcommon-x11-devel` is installed.

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let libs_dir = std::path::Path::new(&manifest_dir).join(".link-libs");
    let alias = libs_dir.join("libxkbcommon-x11.so");

    if !alias.exists() {
        std::fs::create_dir_all(&libs_dir).expect("create .link-libs");
        if let Err(err) = std::os::unix::fs::symlink("/usr/lib64/libxkbcommon-x11.so.0", &alias) {
            panic!("could not create {:?}: {err}", alias);
        }
    }

    println!("cargo:rustc-link-search=native={}", libs_dir.display());
    println!("cargo:rerun-if-changed=build.rs");
}
