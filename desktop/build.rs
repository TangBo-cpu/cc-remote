fn main() {
    use std::{env, fs, path::PathBuf, process::Command};

    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let manifest = root.join("app.manifest");
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
    println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());

    println!("cargo:rerun-if-changed=icon.rc");
    println!("cargo:rerun-if-changed=assets/icon.ico");
    println!("cargo:rerun-if-env-changed=WindowsSdkDir");
    let sdk = env::var_os("WindowsSdkDir")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let output = Command::new("reg.exe")
                .args([
                    "query",
                    r"HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
                    "/v",
                    "KitsRoot10",
                    "/reg:32",
                ])
                .output()
                .expect("Cannot locate the Windows SDK");
            assert!(
                output.status.success(),
                "Install the Windows SDK / C++ build tools"
            );
            let text = String::from_utf8_lossy(&output.stdout);
            PathBuf::from(
                text.lines()
                    .find_map(|line| line.split_once("REG_SZ").map(|(_, value)| value.trim()))
                    .expect("Windows SDK path is missing"),
            )
        });
    let compiler = fs::read_dir(sdk.join("bin"))
        .expect("Windows SDK bin directory is missing")
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("x64/rc.exe"))
        .filter(|path| path.is_file())
        .max()
        .expect("Windows SDK resource compiler is missing");
    let resource = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("icon.res");
    let status = Command::new(compiler)
        .current_dir(&root)
        .arg("/nologo")
        .arg("/fo")
        .arg(&resource)
        .arg("icon.rc")
        .status()
        .expect("Cannot run the Windows resource compiler");
    assert!(status.success(), "Icon resource compilation failed");
    println!("cargo:rustc-link-arg={}", resource.display());
}
