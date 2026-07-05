//! Builds the `gvt` static library (calyx-session/shim) via `zig build`
//! and links it into this crate.
//!
//! Zig toolchain selection: ghostty pins a specific Zig version in its
//! `build.zig.zon` (`minimum_zig_version`), which the `zig` on PATH may
//! not match. Set `GVT_ZIG` to an absolute path to an ABI-compatible zig
//! binary to override; it defaults to `zig` (resolved via PATH).

use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Maps a cargo target triple to the equivalent `zig build -Dtarget`
/// value. Returns `None` for triples without a known mapping.
fn zig_target(cargo_target: &str) -> Option<&'static str> {
    Some(match cargo_target {
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        _ => return None,
    })
}

fn main() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set by cargo"));
    let shim_dir = manifest_dir.join("../../shim");
    let ghostty_dir = shim_dir.join("../../ghostty");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set by cargo"));
    let zig = env::var("GVT_ZIG").unwrap_or_else(|_| "zig".to_string());

    println!("cargo:rerun-if-env-changed=GVT_ZIG");
    println!("cargo:rerun-if-changed={}", shim_dir.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        shim_dir.join("build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        shim_dir.join("build.zig.zon").display()
    );
    // The shim's real input set includes the ghostty-vt sources it
    // builds against (a zig path dependency cargo can't see on its own).
    println!(
        "cargo:rerun-if-changed={}",
        ghostty_dir.join("src").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        ghostty_dir.join("build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        ghostty_dir.join("build.zig.zon").display()
    );

    let mut cmd = Command::new(&zig);
    cmd.current_dir(&shim_dir)
        .args(["build", "install", "--prefix"])
        .arg(&out_dir)
        // Keep zig's cache out of the source tree so concurrent and
        // per-profile builds don't collide there.
        .arg("--cache-dir")
        .arg(out_dir.join("zig-cache"));

    let target = env::var("TARGET").expect("TARGET is set by cargo");
    match zig_target(&target) {
        Some(t) => {
            cmd.arg(format!("-Dtarget={t}"));
        }
        None => println!(
            "cargo:warning=vt-sys: no zig target mapping for `{target}`; \
             building the gvt shim for zig's native target"
        ),
    }

    // ReleaseSafe (not ReleaseFast) so bounds/overflow checks stay
    // active in release builds: the shim's C-boundary contract routes
    // failures through error codes or a controlled abort, never
    // undefined behavior.
    let profile = env::var("PROFILE").expect("PROFILE is set by cargo");
    let optimize = if profile == "release" {
        "ReleaseSafe"
    } else {
        "Debug"
    };
    cmd.arg(format!("-Doptimize={optimize}"));

    let status = cmd.status().unwrap_or_else(|e| {
        panic!(
            "failed to spawn `{zig}` to build the gvt shim in {}: {e}\n\
             hint: the `zig` resolved from PATH may not exist or may be \
             the wrong version; set GVT_ZIG to an absolute path, e.g.\n\
             GVT_ZIG=/opt/homebrew/Cellar/zig/0.15.2/bin/zig cargo test",
            shim_dir.display(),
        )
    });

    if !status.success() {
        panic!(
            "`{zig} build install --prefix {}` failed with {status} \
             (shim dir: {})",
            out_dir.display(),
            shim_dir.display(),
        );
    }

    println!(
        "cargo:rustc-link-search=native={}",
        out_dir.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=gvt");
}
