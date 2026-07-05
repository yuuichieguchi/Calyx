//! `calyx-session remote-install <host>`: deploys the session daemon
//! (and, optionally, the ghostty terminfo entry) to a remote host over
//! ssh.
//!
//! TDD Red phase, P5 (remote sessions), cycle 3. This module's pure
//! logic (arch detection, argv construction, orchestration) is left
//! with `unimplemented!()` bodies; only the type/function *signatures*
//! and the `#[cfg(test)]` module below exist yet. This is a deliberate
//! departure from this codebase's Swift-side "held-out compile-fail
//! file" RED convention (see e.g.
//! `SessionCommandSynthesizerRemoteAttachTests.swift`'s header): `cargo
//! test --workspace` compiles the *entire* workspace before running
//! *any* test in *any* crate, so leaving this crate uncompilable would
//! also block the already-green `vt`/`proto`/`daemon` suites from
//! running in the same invocation. Signatures-with-`unimplemented!()`
//! plus real runtime-assertion tests keep the workspace compiling
//! while still failing for the right reason (a panic naming this
//! module, or an assertion mismatch) -- the accepted Rust-side RED
//! pattern for this codebase.
//!
//! DESIGN NOTES (mirrors `SessionCommandSynthesizer.remoteAttachCommand`
//! on the Swift side, see that file's header for the live-verified
//! transcript this reasoning depends on):
//!
//! - `-- ` BEFORE THE HOST on every `ssh` invocation: without it, a
//!   dash-leading host (e.g. `-evilhost`) can be misparsed as an `ssh`
//!   option rather than the destination argument. Verified live against
//!   the system `ssh` (OpenSSH_10.2p1): `ssh -- -evilhost ...` rejects
//!   `-evilhost` as an invalid *hostname* (treated as the destination),
//!   while `ssh -evilhost ...` (no `--`) instead parses it as `-e
//!   vilhost`, an ordinary short option.
//!
//! - NO local shell layer: unlike the Swift side (which hands ghostty a
//!   single string ultimately run through `/bin/sh -c`), this CLI execs
//!   `ssh` directly via argv (no `Command::new("sh").arg("-c")`
//!   anywhere), so there is exactly ONE shell in play: the REMOTE
//!   login shell that `ssh` itself invokes to run its trailing argv
//!   words. `ssh` joins those trailing words with a single space and
//!   hands the joined string to that remote shell -- this is documented
//!   `ssh` behavior, not a Rust-side assumption -- so a remote path
//!   embedded as several separate argv words (e.g. `"cat"`, `">"`,
//!   `"$HOME/.calyx/bin/calyx-session"`) reassembles correctly on the
//!   wire and is parsed exactly once, remotely.
//!
//! - `$HOME`, NOT `~`, and always UNQUOTED in the remote command: a
//!   single-quoted `'$HOME/.calyx/bin'` would be WRONG, because single
//!   quotes suppress both tilde expansion and `$HOME` parameter
//!   expansion on every POSIX shell, making it a literal string on the
//!   remote end instead of a path. `$HOME` is left as a plain, unquoted
//!   bareword so the REMOTE shell's own parameter expansion resolves it
//!   against the REMOTE user's home directory. `$HOME` (not `~`) is
//!   used because tilde expansion is a shell-specific convenience not
//!   guaranteed identical across every POSIX `/bin/sh` a remote login
//!   shell might be, whereas `$HOME` parameter expansion is POSIX-
//!   mandated.
//!
//! - TRANSFER VIA `ssh ... 'cat > path'` (stdin-piped), NOT `scp`: since
//!   OpenSSH 9.0, `scp` defaults to the SFTP protocol for the transfer,
//!   which does its own path resolution against the SFTP subsystem and
//!   does NOT invoke a remote shell to parse the destination path at
//!   all -- a literal `$HOME` in an scp destination would need scp/sftp
//!   itself to expand it (uncertain/inconsistent across
//!   implementations), whereas legacy scp uses different quoting rules
//!   again. Piping the local payload into `ssh <host> cat > <path>`
//!   keeps exactly one code path (an `ssh` argv, joined and parsed by
//!   ONE real remote shell) for every remote operation this module
//!   performs -- detection, mkdir, transfer, chmod -- with one single,
//!   already-reasoned-about set of quoting rules, instead of mixing two
//!   transports with two different expansion semantics.
//!
//! - THE BINARY TRANSFER AND ITS `chmod 755` SHARE ONE ssh INVOCATION
//!   (`transfer_and_chmod_command`, joined with `&&`): this halves the
//!   network round-trips for the required step (the daemon binary must
//!   both exist and be executable for anything else to work) versus two
//!   separate `ssh` calls.
//!
//! - TERMINFO FAILURE IS A WARNING, NOT AN ERROR: `remote_install`
//!   still returns `Ok` if the terminfo mkdir/transfer step fails,
//!   recording a warning in `RemoteInstallSummary` instead. A remote
//!   session still works with `TERM=xterm-256color` if the ghostty
//!   terminfo entry never arrives; a broken/read-only
//!   `~/.terminfo` on the remote host should not block getting the
//!   daemon itself installed.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use crate::cli::RemoteInstallArgs;
use crate::commands::CommandError;

/// Remote path (`$HOME`-relative, unquoted -- see this module's header)
/// of the directory the calyx-session binary is installed into.
pub const REMOTE_BIN_DIR: &str = "$HOME/.calyx/bin";
/// Remote path of the installed calyx-session binary itself.
pub const REMOTE_BIN_PATH: &str = "$HOME/.calyx/bin/calyx-session";
/// Remote path of the directory the ghostty terminfo entry is
/// installed into (`x/` matches ncurses' hashed-by-first-letter
/// terminfo database layout).
pub const REMOTE_TERMINFO_DIR: &str = "$HOME/.terminfo/x";
/// Remote path of the installed ghostty terminfo entry.
pub const REMOTE_TERMINFO_PATH: &str = "$HOME/.terminfo/x/xterm-ghostty";

// ==================== R1: arch detection ====================

/// The remote host's OS/CPU architecture, as reported by `uname -sm`
/// and restricted to the combinations calyx-session ships a payload
/// for. Producing a value of this type already means the platform is
/// supported -- unsupported/unrecognized combinations are rejected by
/// [`parse_uname_sm`] itself, as an [`ArchDetectError`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteArch {
    LinuxX86_64,
    LinuxAarch64,
    /// Apple Silicon macOS.
    DarwinArm64,
}

impl fmt::Display for RemoteArch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            RemoteArch::LinuxX86_64 => "Linux x86_64",
            RemoteArch::LinuxAarch64 => "Linux aarch64",
            RemoteArch::DarwinArm64 => "Darwin arm64",
        })
    }
}

/// Which local artifact to send for a given [`RemoteArch`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadKind {
    LinuxX86_64,
    LinuxAarch64,
    /// Reuse the local host's own calyx-session binary as-is: a Darwin
    /// arm64 remote is bit-for-bit the same target this Mac itself
    /// builds, so no separate cross-compiled payload exists for it.
    HostBinary,
}

/// Why [`parse_uname_sm`] could not produce a [`RemoteArch`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchDetectError {
    /// `uname -sm`'s output didn't parse into exactly two
    /// whitespace-separated tokens (an OS name and a machine name).
    /// Carries the raw output for the error message.
    Malformed(String),
    /// Parsed into two tokens, but this OS/machine combination has no
    /// shipped payload (e.g. Intel macOS, which is out of scope, or any
    /// OS calyx-session doesn't build for).
    Unsupported { os: String, machine: String },
}

impl fmt::Display for ArchDetectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ArchDetectError::Malformed(raw) => {
                write!(f, "could not parse `uname -sm` output: {raw:?}")
            }
            ArchDetectError::Unsupported { os, machine } => {
                write!(
                    f,
                    "unsupported remote platform: {os} {machine} (no calyx-session payload is built for it)"
                )
            }
        }
    }
}

impl std::error::Error for ArchDetectError {}

/// Parses `uname -sm`'s output into a [`RemoteArch`]. Tolerant of
/// leading/trailing whitespace and of internal whitespace runs other
/// than a single space (`uname`'s own output, and whatever `ssh`/the
/// remote shell might add around it).
pub fn parse_uname_sm(output: &str) -> Result<RemoteArch, ArchDetectError> {
    let trimmed = output.trim();
    let tokens: Vec<&str> = trimmed.split_whitespace().collect();
    let [os, machine] = tokens.as_slice() else {
        return Err(ArchDetectError::Malformed(trimmed.to_string()));
    };
    match (*os, *machine) {
        ("Linux", "x86_64") => Ok(RemoteArch::LinuxX86_64),
        ("Linux", "aarch64") => Ok(RemoteArch::LinuxAarch64),
        ("Darwin", "arm64") => Ok(RemoteArch::DarwinArm64),
        _ => Err(ArchDetectError::Unsupported {
            os: os.to_string(),
            machine: machine.to_string(),
        }),
    }
}

/// Maps an already-supported [`RemoteArch`] to the local artifact that
/// must be sent for it. Total (never fails): [`parse_uname_sm`] is the
/// single place unsupported architectures are rejected.
pub fn payload_for(arch: RemoteArch) -> PayloadKind {
    match arch {
        RemoteArch::LinuxX86_64 => PayloadKind::LinuxX86_64,
        RemoteArch::LinuxAarch64 => PayloadKind::LinuxAarch64,
        RemoteArch::DarwinArm64 => PayloadKind::HostBinary,
    }
}

// ==================== R3: argv construction ====================

/// Builds `ssh -- <host> uname -sm`, the detection step run against the
/// remote host before anything else. `--` precedes `host` so a
/// dash-leading host cannot be misparsed as an `ssh` option (see this
/// module's header).
pub fn detect_command(host: &str) -> Vec<String> {
    ssh_argv(host, &["uname", "-sm"])
}

/// Builds `ssh -- <host> mkdir -p <remote_dir>`.
pub fn mkdir_command(host: &str, remote_dir: &str) -> Vec<String> {
    ssh_argv(host, &["mkdir", "-p", remote_dir])
}

/// Builds `ssh -- <host> cat > <remote_path> && chmod 755
/// <remote_path>`. The caller pipes the local payload file's bytes into
/// the returned argv's stdin (see [`CommandRunner::run_with_stdin_file`]);
/// `cat`'s own stdin becomes that piped data once `ssh` forwards it to
/// the remote `cat` process. Combines the transfer and the chmod into
/// one `ssh` invocation (see this module's header).
pub fn transfer_and_chmod_command(host: &str, remote_path: &str) -> Vec<String> {
    ssh_argv(
        host,
        &["cat", ">", remote_path, "&&", "chmod", "755", remote_path],
    )
}

/// Builds `ssh -- <host> cat > <remote_path>` (no chmod: the terminfo
/// entry never needs to be executable).
pub fn transfer_command(host: &str, remote_path: &str) -> Vec<String> {
    ssh_argv(host, &["cat", ">", remote_path])
}

/// Shared shape of every remote invocation this module builds:
/// `ssh -- <host> <remote words...>`, with `--` always preceding the
/// host (see this module's header on dash-leading hosts).
fn ssh_argv(host: &str, remote_words: &[&str]) -> Vec<String> {
    let mut argv = vec!["ssh".to_string(), "--".to_string(), host.to_string()];
    argv.extend(remote_words.iter().map(|w| w.to_string()));
    argv
}

// ==================== R4: runner trait + orchestration ====================

/// Minimal projection of a finished child process's result. Deliberately
/// NOT `std::process::Output` (whose `ExitStatus` has no stable,
/// portable "just construct one" API outside real process spawning),
/// so unit tests can build fake results directly.
#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Runs a subprocess given its argv (`argv[0]` is the program). Kept
/// injectable so [`remote_install`]'s orchestration is unit-testable
/// without a network, without `ssh` even being installed, and without
/// touching any real remote host. Mirrors the
/// `SSHBinaryResolverProtocol`/command-runner seam pattern already used
/// on the Swift side of this feature.
pub trait CommandRunner {
    /// Runs `argv[0]` with `argv[1..]` as its arguments; stdin is
    /// closed/null.
    fn run(&self, argv: &[String]) -> io::Result<CommandOutput>;

    /// Same as [`run`](CommandRunner::run), but `argv[0]`'s stdin is
    /// connected to `stdin_path`'s contents. Used to stream a local
    /// payload file (the calyx-session binary, the terminfo entry) into
    /// a remote `cat > <path>` without this crate ever loading the
    /// whole file into memory itself.
    fn run_with_stdin_file(&self, argv: &[String], stdin_path: &Path) -> io::Result<CommandOutput>;
}

/// Inputs to [`remote_install`]: the already-parsed [`RemoteInstallArgs`]
/// borrowed field-by-field, so this can be constructed both from a real
/// CLI invocation and from a test fixture without cloning paths.
pub struct RemoteInstallInputs<'a> {
    pub host: &'a str,
    pub payload_x86_64: Option<&'a Path>,
    pub payload_aarch64: Option<&'a Path>,
    pub host_binary: Option<&'a Path>,
    pub terminfo: Option<&'a Path>,
}

/// Successful outcome of [`remote_install`].
#[derive(Debug, PartialEq, Eq)]
pub struct RemoteInstallSummary {
    pub arch: RemoteArch,
    /// `Some(message)` when the terminfo mkdir/transfer step failed.
    /// The binary install itself still succeeded (see this module's
    /// header: terminfo failure is a warning, not an error).
    pub terminfo_warning: Option<String>,
}

/// Why [`remote_install`] failed. Every variant here means NO further
/// install step ran after the failure (fail-fast): a detection/arch/
/// missing-payload failure means no transfer step ever ran at all; a
/// binary transfer failure means the terminfo step (if any) never ran
/// either.
#[derive(Debug)]
pub enum RemoteInstallError {
    /// The detection `ssh` invocation itself could not be run (e.g. no
    /// local `ssh` binary).
    Detect(io::Error),
    /// The detection `ssh` invocation ran but exited non-zero; carries
    /// its stderr.
    DetectFailed(String),
    /// `uname -sm`'s output didn't map to a supported [`RemoteArch`].
    Arch(ArchDetectError),
    /// The detected architecture needs a payload flag that was not
    /// given. Carries the flag's exact name (e.g. `"--payload-aarch64"`)
    /// for the error message.
    MissingPayload(&'static str),
    /// A remote `mkdir -p` step (for the binary or the terminfo
    /// directory) failed; carries its stderr.
    Mkdir(String),
    /// The binary transfer+chmod step failed; carries its stderr.
    Transfer(String),
}

impl fmt::Display for RemoteInstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RemoteInstallError::Detect(e) => {
                write!(f, "remote-install: could not run `ssh -- <host> uname -sm`: {e}")
            }
            RemoteInstallError::DetectFailed(stderr) => {
                write!(f, "remote-install: `ssh -- <host> uname -sm` exited non-zero: {stderr}")
            }
            RemoteInstallError::Arch(e) => write!(f, "remote-install: {e}"),
            RemoteInstallError::MissingPayload(flag) => write!(
                f,
                "remote-install: the detected remote architecture needs `{flag}`, which was not given"
            ),
            RemoteInstallError::Mkdir(stderr) => {
                write!(f, "remote-install: failed to create a remote directory: {stderr}")
            }
            RemoteInstallError::Transfer(stderr) => write!(
                f,
                "remote-install: failed to transfer the calyx-session binary: {stderr}"
            ),
        }
    }
}

impl std::error::Error for RemoteInstallError {}

/// Detects the remote host's architecture, then transfers the matching
/// payload binary (and, best-effort, the terminfo entry) to it. Runs
/// every remote operation through `runner`, never touching a network
/// socket or a shell directly itself.
pub fn remote_install(
    runner: &dyn CommandRunner,
    inputs: &RemoteInstallInputs,
) -> Result<RemoteInstallSummary, RemoteInstallError> {
    let detect = runner
        .run(&detect_command(inputs.host))
        .map_err(RemoteInstallError::Detect)?;
    if !detect.success {
        return Err(RemoteInstallError::DetectFailed(lossy(&detect.stderr)));
    }
    let arch = parse_uname_sm(&String::from_utf8_lossy(&detect.stdout))
        .map_err(RemoteInstallError::Arch)?;

    let payload = match payload_for(arch) {
        PayloadKind::LinuxX86_64 => inputs
            .payload_x86_64
            .ok_or(RemoteInstallError::MissingPayload("--payload-x86-64"))?,
        PayloadKind::LinuxAarch64 => inputs
            .payload_aarch64
            .ok_or(RemoteInstallError::MissingPayload("--payload-aarch64"))?,
        PayloadKind::HostBinary => inputs
            .host_binary
            .ok_or(RemoteInstallError::MissingPayload("--host-binary"))?,
    };

    let mkdir = runner
        .run(&mkdir_command(inputs.host, REMOTE_BIN_DIR))
        .map_err(|e| RemoteInstallError::Mkdir(e.to_string()))?;
    if !mkdir.success {
        return Err(RemoteInstallError::Mkdir(lossy(&mkdir.stderr)));
    }

    let transfer = runner
        .run_with_stdin_file(
            &transfer_and_chmod_command(inputs.host, REMOTE_BIN_PATH),
            payload,
        )
        .map_err(|e| RemoteInstallError::Transfer(e.to_string()))?;
    if !transfer.success {
        return Err(RemoteInstallError::Transfer(lossy(&transfer.stderr)));
    }

    let terminfo_warning = match inputs.terminfo {
        Some(terminfo) => install_terminfo(runner, inputs.host, terminfo).err(),
        None => None,
    };

    Ok(RemoteInstallSummary {
        arch,
        terminfo_warning,
    })
}

/// The best-effort terminfo step: remote mkdir, then transfer. Returns
/// the would-be warning message on failure; [`remote_install`] records
/// it in the summary instead of failing (see this module's header).
fn install_terminfo(runner: &dyn CommandRunner, host: &str, terminfo: &Path) -> Result<(), String> {
    let mkdir = runner
        .run(&mkdir_command(host, REMOTE_TERMINFO_DIR))
        .map_err(|e| format!("could not run the terminfo mkdir step: {e}"))?;
    if !mkdir.success {
        return Err(format!(
            "failed to create {REMOTE_TERMINFO_DIR} remotely: {}",
            lossy(&mkdir.stderr)
        ));
    }
    let transfer = runner
        .run_with_stdin_file(&transfer_command(host, REMOTE_TERMINFO_PATH), terminfo)
        .map_err(|e| format!("could not run the terminfo transfer step: {e}"))?;
    if !transfer.success {
        return Err(format!(
            "failed to transfer the terminfo entry to {REMOTE_TERMINFO_PATH}: {}",
            lossy(&transfer.stderr)
        ));
    }
    Ok(())
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim_end().to_string()
}

/// The production [`CommandRunner`]: real `std::process::Command`
/// spawning, with stdout/stderr captured. Unit tests never construct
/// this; they script a fake runner instead (see the tests below).
pub struct ProcessRunner;

impl CommandRunner for ProcessRunner {
    fn run(&self, argv: &[String]) -> io::Result<CommandOutput> {
        run_process(argv, std::process::Stdio::null())
    }

    fn run_with_stdin_file(&self, argv: &[String], stdin_path: &Path) -> io::Result<CommandOutput> {
        let payload = std::fs::File::open(stdin_path)?;
        run_process(argv, std::process::Stdio::from(payload))
    }
}

fn run_process(argv: &[String], stdin: std::process::Stdio) -> io::Result<CommandOutput> {
    let (program, args) = argv.split_first().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "empty argv given to ProcessRunner",
        )
    })?;
    let output = std::process::Command::new(program)
        .args(args)
        .stdin(stdin)
        .output()?;
    Ok(CommandOutput {
        success: output.status.success(),
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

/// `calyx-session remote-install <host>` entry point, called from
/// `main.rs`. `runtime_dir`/`state_dir` are accepted (so the global CLI
/// parser stays uniform across every subcommand) but unused: they name
/// local daemon directories, which are meaningless for a remote
/// install.
pub fn run(
    _runtime_dir: &Option<PathBuf>,
    _state_dir: &Option<PathBuf>,
    args: RemoteInstallArgs,
) -> Result<u8, CommandError> {
    let inputs = RemoteInstallInputs {
        host: &args.host,
        payload_x86_64: args.payload_x86_64.as_deref(),
        payload_aarch64: args.payload_aarch64.as_deref(),
        host_binary: args.host_binary.as_deref(),
        terminfo: args.terminfo.as_deref(),
    };
    let summary = remote_install(&ProcessRunner, &inputs)?;
    println!(
        "installed calyx-session ({}) at {REMOTE_BIN_PATH} on {}",
        summary.arch, args.host
    );
    match &summary.terminfo_warning {
        Some(warning) => {
            eprintln!("warning: {warning} (remote sessions still work with TERM=xterm-256color)")
        }
        None => {
            if args.terminfo.is_some() {
                println!("installed the ghostty terminfo entry at {REMOTE_TERMINFO_PATH}");
            }
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    use std::cell::RefCell;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::process::Stdio;

    // ==================== R1: arch mapping ====================

    #[test]
    fn parse_uname_sm_maps_linux_x86_64() {
        assert_eq!(parse_uname_sm("Linux x86_64"), Ok(RemoteArch::LinuxX86_64));
    }

    #[test]
    fn parse_uname_sm_maps_linux_aarch64() {
        assert_eq!(
            parse_uname_sm("Linux aarch64"),
            Ok(RemoteArch::LinuxAarch64)
        );
    }

    #[test]
    fn parse_uname_sm_maps_darwin_arm64() {
        assert_eq!(parse_uname_sm("Darwin arm64"), Ok(RemoteArch::DarwinArm64));
    }

    #[test]
    fn parse_uname_sm_tolerates_surrounding_and_internal_whitespace() {
        assert_eq!(
            parse_uname_sm("  Linux\tx86_64  \n"),
            Ok(RemoteArch::LinuxX86_64)
        );
    }

    #[test]
    fn parse_uname_sm_rejects_darwin_x86_64_as_unsupported() {
        let err = parse_uname_sm("Darwin x86_64").unwrap_err();
        assert_eq!(
            err,
            ArchDetectError::Unsupported {
                os: "Darwin".into(),
                machine: "x86_64".into(),
            }
        );
        let message = err.to_string();
        assert!(
            message.contains("Darwin"),
            "message should name the OS: {message}"
        );
        assert!(
            message.contains("x86_64"),
            "message should name the machine: {message}"
        );
    }

    #[test]
    fn parse_uname_sm_rejects_unrecognized_platform_with_a_clear_message() {
        let err = parse_uname_sm("SunOS sun4u").unwrap_err();
        assert_eq!(
            err,
            ArchDetectError::Unsupported {
                os: "SunOS".into(),
                machine: "sun4u".into(),
            }
        );
    }

    #[test]
    fn parse_uname_sm_rejects_empty_output_as_malformed() {
        assert_eq!(
            parse_uname_sm(""),
            Err(ArchDetectError::Malformed(String::new()))
        );
    }

    #[test]
    fn parse_uname_sm_rejects_a_single_token_as_malformed() {
        assert_eq!(
            parse_uname_sm("Linux"),
            Err(ArchDetectError::Malformed("Linux".into()))
        );
    }

    #[test]
    fn parse_uname_sm_rejects_extra_trailing_tokens_as_malformed() {
        assert_eq!(
            parse_uname_sm("Linux x86_64 extra"),
            Err(ArchDetectError::Malformed("Linux x86_64 extra".into()))
        );
    }

    #[test]
    fn payload_for_maps_linux_x86_64_to_the_linux_x86_64_payload() {
        assert_eq!(
            payload_for(RemoteArch::LinuxX86_64),
            PayloadKind::LinuxX86_64
        );
    }

    #[test]
    fn payload_for_maps_linux_aarch64_to_the_linux_aarch64_payload() {
        assert_eq!(
            payload_for(RemoteArch::LinuxAarch64),
            PayloadKind::LinuxAarch64
        );
    }

    #[test]
    fn payload_for_maps_darwin_arm64_to_the_host_binary() {
        assert_eq!(
            payload_for(RemoteArch::DarwinArm64),
            PayloadKind::HostBinary
        );
    }

    // ==================== R2: CLI surface ====================

    #[test]
    fn cli_parses_remote_install_with_host_and_all_payload_flags() {
        let cli = crate::cli::Cli::try_parse_from([
            "calyx-session",
            "remote-install",
            "myhost",
            "--payload-x86-64",
            "/tmp/payload-x86_64",
            "--payload-aarch64",
            "/tmp/payload-aarch64",
            "--host-binary",
            "/tmp/host-binary",
            "--terminfo",
            "/tmp/terminfo",
        ])
        .expect("remote-install with all flags should parse");

        match cli.command {
            crate::cli::Command::RemoteInstall(args) => {
                assert_eq!(args.host, "myhost");
                assert_eq!(
                    args.payload_x86_64.as_deref(),
                    Some(Path::new("/tmp/payload-x86_64"))
                );
                assert_eq!(
                    args.payload_aarch64.as_deref(),
                    Some(Path::new("/tmp/payload-aarch64"))
                );
                assert_eq!(
                    args.host_binary.as_deref(),
                    Some(Path::new("/tmp/host-binary"))
                );
                assert_eq!(args.terminfo.as_deref(), Some(Path::new("/tmp/terminfo")));
            }
            other => panic!("expected Command::RemoteInstall, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_remote_install_with_only_the_host_all_payload_flags_optional() {
        let cli = crate::cli::Cli::try_parse_from(["calyx-session", "remote-install", "myhost"])
            .expect(
                "remote-install with only the host should parse: which payload flag is \
                 required depends on runtime ssh detection, which clap cannot know about",
            );
        match cli.command {
            crate::cli::Command::RemoteInstall(args) => {
                assert_eq!(args.host, "myhost");
                assert_eq!(args.payload_x86_64, None);
                assert_eq!(args.payload_aarch64, None);
                assert_eq!(args.host_binary, None);
                assert_eq!(args.terminfo, None);
            }
            other => panic!("expected Command::RemoteInstall, got {other:?}"),
        }
    }

    #[test]
    fn cli_remote_install_requires_the_host_positional() {
        let result = crate::cli::Cli::try_parse_from(["calyx-session", "remote-install"]);
        assert!(
            result.is_err(),
            "remote-install with no host should be a parse error"
        );
    }

    #[test]
    fn cli_remote_install_still_accepts_the_global_runtime_and_state_dir_flags() {
        let cli = crate::cli::Cli::try_parse_from([
            "calyx-session",
            "--runtime-dir",
            "/tmp/run",
            "--state-dir",
            "/tmp/state",
            "remote-install",
            "myhost",
        ])
        .expect("global flags should still parse ahead of remote-install");
        assert_eq!(cli.runtime_dir.as_deref(), Some(Path::new("/tmp/run")));
        assert_eq!(cli.state_dir.as_deref(), Some(Path::new("/tmp/state")));
        assert!(matches!(cli.command, crate::cli::Command::RemoteInstall(_)));
    }

    // ==================== R3: argv construction ====================

    #[test]
    fn detect_command_puts_dash_dash_before_the_host() {
        assert_eq!(
            detect_command("myhost"),
            vec!["ssh", "--", "myhost", "uname", "-sm"]
        );
    }

    /// Regression guard for the option-injection hardening this module's
    /// header documents: a dash-leading host must still arrive as one
    /// intact argv word placed immediately after `--`, never split or
    /// reordered. See this module's header for the live-verified `ssh`
    /// transcript this design depends on.
    #[test]
    fn detect_command_keeps_a_dash_leading_host_as_one_intact_word_after_dash_dash() {
        assert_eq!(
            detect_command("-evilhost"),
            vec!["ssh", "--", "-evilhost", "uname", "-sm"]
        );
    }

    #[test]
    fn mkdir_command_targets_the_given_remote_dir_after_dash_dash_host() {
        assert_eq!(
            mkdir_command("myhost", REMOTE_BIN_DIR),
            vec!["ssh", "--", "myhost", "mkdir", "-p", "$HOME/.calyx/bin"]
        );
    }

    #[test]
    fn transfer_and_chmod_command_never_single_quotes_home() {
        let argv = transfer_and_chmod_command("myhost", REMOTE_BIN_PATH);
        assert_eq!(
            argv,
            vec![
                "ssh",
                "--",
                "myhost",
                "cat",
                ">",
                "$HOME/.calyx/bin/calyx-session",
                "&&",
                "chmod",
                "755",
                "$HOME/.calyx/bin/calyx-session",
            ]
        );
        for word in &argv {
            assert!(
                !word.contains("'$HOME") && !word.contains("'~"),
                "remote command word must never single-quote $HOME or ~ \
                 (single quotes suppress remote-shell expansion): {word:?}"
            );
        }
    }

    #[test]
    fn transfer_command_for_terminfo_has_no_chmod_step() {
        assert_eq!(
            transfer_command("myhost", REMOTE_TERMINFO_PATH),
            vec![
                "ssh",
                "--",
                "myhost",
                "cat",
                ">",
                "$HOME/.terminfo/x/xterm-ghostty"
            ]
        );
    }

    /// Proves the constructed remote command word actually EXPANDS
    /// `$HOME`, instead of merely asserting a substring. `ssh` joins its
    /// trailing argv words with a single space and hands the result to
    /// the remote login shell for parsing -- documented `ssh` behavior,
    /// not a Rust-side assumption. This test reproduces that exact
    /// join-then-shell-parse step LOCALLY via `/bin/sh -c`, with `HOME`
    /// overridden to a scratch directory: a regression back to a
    /// single-quoted `'$HOME'` (which every POSIX shell parses as a
    /// literal string, never expanded) would make this test fail, since
    /// the file would then never appear under the scratch `HOME` at all.
    #[test]
    fn transfer_and_chmod_remote_command_word_expands_home_under_a_real_shell() {
        let tempdir = tempfile::tempdir().expect("create scratch tempdir");

        // Precondition mirroring remote_install's real step order: the
        // separate `mkdir -p $HOME/.calyx/bin` ssh step always runs
        // before the transfer, so replay it (proving ITS $HOME
        // expansion too) through the same join-then-shell-parse
        // mechanism first. (Spec amendment approved by the lead after
        // GREEN found the original RED test unsatisfiable without this
        // precondition.)
        let mkdir_remote = mkdir_command("myhost", REMOTE_BIN_DIR)[3..].join(" ");
        let mkdir_status = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(&mkdir_remote)
            .env("HOME", tempdir.path())
            .status()
            .expect("spawn /bin/sh -c for the constructed mkdir command");
        assert!(
            mkdir_status.success(),
            "constructed mkdir command should exit 0 under a real shell, got {mkdir_status:?}"
        );

        let argv = transfer_and_chmod_command("myhost", REMOTE_BIN_PATH);
        // argv[0..=2] is ["ssh", "--", "myhost"]; argv[3..] is exactly
        // what `ssh` would join with single spaces and send over the
        // wire for the remote shell to parse.
        let remote_command = argv[3..].join(" ");

        let payload = b"#!/bin/sh\necho payload\n";
        let mut child = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(&remote_command)
            .env("HOME", tempdir.path())
            .stdin(Stdio::piped())
            .spawn()
            .expect("spawn /bin/sh -c for the constructed remote command");
        child
            .stdin
            .take()
            .expect("piped stdin")
            .write_all(payload)
            .expect("pipe the fake payload into the remote command's stdin");
        let status = child
            .wait()
            .expect("wait for the constructed remote command");
        assert!(
            status.success(),
            "constructed remote command should exit 0 under a real shell, got {status:?}"
        );

        let installed = tempdir.path().join(".calyx/bin/calyx-session");
        let written = std::fs::read(&installed).unwrap_or_else(|e| {
            panic!(
                "expected {} to exist after $HOME expansion under HOME={}: {e}",
                installed.display(),
                tempdir.path().display()
            )
        });
        assert_eq!(
            written, payload,
            "the transferred file's content should match what was piped in as stdin"
        );

        let mode = std::fs::metadata(&installed)
            .expect("stat the installed file")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(
            mode, 0o755,
            "installed binary should end up chmod 755, got {mode:o}"
        );
    }

    // ==================== R4: runner trait + orchestration ====================

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum RecordedCall {
        Run(Vec<String>),
        RunWithStdinFile(Vec<String>, PathBuf),
    }

    /// Scripted fake [`CommandRunner`]: returns the next entry of
    /// `responses` (`run`/`run_with_stdin_file` share one queue, in call
    /// order), recording every call it sees. Panics if invoked more
    /// times than scripted, surfacing "the orchestration ran an
    /// extra/unexpected step" as a hard test failure instead of a silent
    /// default.
    #[derive(Default)]
    struct RecordingRunner {
        responses: RefCell<Vec<io::Result<CommandOutput>>>,
        calls: RefCell<Vec<RecordedCall>>,
    }

    impl RecordingRunner {
        fn scripted(responses: Vec<io::Result<CommandOutput>>) -> Self {
            RecordingRunner {
                responses: RefCell::new(responses.into_iter().rev().collect()),
                calls: RefCell::new(Vec::new()),
            }
        }

        fn respond_to(&self, call: RecordedCall) -> io::Result<CommandOutput> {
            self.calls.borrow_mut().push(call.clone());
            self.responses.borrow_mut().pop().unwrap_or_else(|| {
                panic!("RecordingRunner: no scripted response left for {call:?}")
            })
        }
    }

    impl CommandRunner for RecordingRunner {
        fn run(&self, argv: &[String]) -> io::Result<CommandOutput> {
            self.respond_to(RecordedCall::Run(argv.to_vec()))
        }

        fn run_with_stdin_file(
            &self,
            argv: &[String],
            stdin_path: &Path,
        ) -> io::Result<CommandOutput> {
            self.respond_to(RecordedCall::RunWithStdinFile(
                argv.to_vec(),
                stdin_path.to_path_buf(),
            ))
        }
    }

    fn ok(stdout: &str) -> io::Result<CommandOutput> {
        Ok(CommandOutput {
            success: true,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
        })
    }

    fn failed(stderr: &str) -> io::Result<CommandOutput> {
        Ok(CommandOutput {
            success: false,
            stdout: Vec::new(),
            stderr: stderr.as_bytes().to_vec(),
        })
    }

    #[test]
    fn remote_install_fails_fast_on_unsupported_arch_without_running_any_transfer_step() {
        let runner = RecordingRunner::scripted(vec![ok("Darwin x86_64\n")]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(Path::new("/tmp/payload-x86_64")),
            payload_aarch64: Some(Path::new("/tmp/payload-aarch64")),
            host_binary: Some(Path::new("/tmp/host-binary")),
            terminfo: Some(Path::new("/tmp/terminfo")),
        };

        let result = remote_install(&runner, &inputs);

        assert!(
            matches!(result, Err(RemoteInstallError::Arch(_))),
            "expected an Arch error, got {result:?}"
        );
        let calls = runner.calls.borrow();
        assert_eq!(
            calls.len(),
            1,
            "only the detection call should have run, got {calls:?}"
        );
        assert_eq!(calls[0], RecordedCall::Run(detect_command("myhost")));
    }

    #[test]
    fn remote_install_fails_fast_when_detection_itself_errors() {
        let runner =
            RecordingRunner::scripted(vec![Err(io::Error::other("ssh: connection refused"))]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(Path::new("/tmp/payload-x86_64")),
            payload_aarch64: None,
            host_binary: None,
            terminfo: None,
        };

        let result = remote_install(&runner, &inputs);

        assert!(
            matches!(result, Err(RemoteInstallError::Detect(_))),
            "expected a Detect error, got {result:?}"
        );
        assert_eq!(runner.calls.borrow().len(), 1);
    }

    #[test]
    fn remote_install_fails_fast_when_detection_ssh_exits_non_zero() {
        let runner = RecordingRunner::scripted(vec![failed("ssh: Host key verification failed.")]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(Path::new("/tmp/payload-x86_64")),
            payload_aarch64: None,
            host_binary: None,
            terminfo: None,
        };

        let result = remote_install(&runner, &inputs);

        assert!(
            matches!(result, Err(RemoteInstallError::DetectFailed(_))),
            "expected a DetectFailed error, got {result:?}"
        );
        assert_eq!(runner.calls.borrow().len(), 1);
    }

    #[test]
    fn remote_install_fails_fast_when_the_detected_archs_payload_flag_is_missing() {
        let runner = RecordingRunner::scripted(vec![ok("Linux aarch64\n")]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(Path::new("/tmp/payload-x86_64")),
            payload_aarch64: None, // missing -- this is the one detection selected
            host_binary: Some(Path::new("/tmp/host-binary")),
            terminfo: None,
        };

        let result = remote_install(&runner, &inputs);

        match result {
            Err(RemoteInstallError::MissingPayload(flag)) => {
                assert_eq!(flag, "--payload-aarch64")
            }
            other => panic!("expected MissingPayload(\"--payload-aarch64\"), got {other:?}"),
        }
        let calls = runner.calls.borrow();
        assert_eq!(
            calls.len(),
            1,
            "no transfer step should run before the payload check, got {calls:?}"
        );
    }

    #[test]
    fn remote_install_happy_path_runs_mkdir_transfer_chmod_and_terminfo_in_order() {
        let payload = tempfile::NamedTempFile::new().expect("create scratch payload file");
        let terminfo = tempfile::NamedTempFile::new().expect("create scratch terminfo file");
        let runner = RecordingRunner::scripted(vec![
            ok("Linux x86_64\n"), // detect
            ok(""),               // mkdir bin dir
            ok(""),               // transfer + chmod binary
            ok(""),               // mkdir terminfo dir
            ok(""),               // transfer terminfo
        ]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(payload.path()),
            payload_aarch64: None,
            host_binary: None,
            terminfo: Some(terminfo.path()),
        };

        let result = remote_install(&runner, &inputs).expect("happy path should succeed");

        assert_eq!(result.arch, RemoteArch::LinuxX86_64);
        assert_eq!(result.terminfo_warning, None);
        assert_eq!(
            *runner.calls.borrow(),
            vec![
                RecordedCall::Run(detect_command("myhost")),
                RecordedCall::Run(mkdir_command("myhost", REMOTE_BIN_DIR)),
                RecordedCall::RunWithStdinFile(
                    transfer_and_chmod_command("myhost", REMOTE_BIN_PATH),
                    payload.path().to_path_buf(),
                ),
                RecordedCall::Run(mkdir_command("myhost", REMOTE_TERMINFO_DIR)),
                RecordedCall::RunWithStdinFile(
                    transfer_command("myhost", REMOTE_TERMINFO_PATH),
                    terminfo.path().to_path_buf(),
                ),
            ]
        );
    }

    #[test]
    fn remote_install_maps_darwin_arm64_to_the_host_binary_payload() {
        let payload = tempfile::NamedTempFile::new().expect("create scratch payload file");
        let runner = RecordingRunner::scripted(vec![ok("Darwin arm64\n"), ok(""), ok("")]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: None,
            payload_aarch64: None,
            host_binary: Some(payload.path()),
            terminfo: None,
        };

        let result = remote_install(&runner, &inputs)
            .expect("Darwin arm64 with --host-binary should succeed");
        assert_eq!(result.arch, RemoteArch::DarwinArm64);
        assert_eq!(
            *runner.calls.borrow(),
            vec![
                RecordedCall::Run(detect_command("myhost")),
                RecordedCall::Run(mkdir_command("myhost", REMOTE_BIN_DIR)),
                RecordedCall::RunWithStdinFile(
                    transfer_and_chmod_command("myhost", REMOTE_BIN_PATH),
                    payload.path().to_path_buf(),
                ),
            ]
        );
    }

    #[test]
    fn remote_install_binary_transfer_failure_is_an_error() {
        let payload = tempfile::NamedTempFile::new().expect("create scratch payload file");
        let runner = RecordingRunner::scripted(vec![
            ok("Linux x86_64\n"),
            ok(""),
            failed("scp: permission denied"),
        ]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(payload.path()),
            payload_aarch64: None,
            host_binary: None,
            terminfo: None,
        };

        let result = remote_install(&runner, &inputs);
        assert!(
            matches!(result, Err(RemoteInstallError::Transfer(_))),
            "expected a Transfer error, got {result:?}"
        );
    }

    #[test]
    fn remote_install_terminfo_failure_is_a_warning_not_an_error() {
        let payload = tempfile::NamedTempFile::new().expect("create scratch payload file");
        let terminfo = tempfile::NamedTempFile::new().expect("create scratch terminfo file");
        let runner = RecordingRunner::scripted(vec![
            ok("Linux x86_64\n"),
            ok(""),
            ok(""),
            failed("mkdir: permission denied"), // terminfo mkdir fails
        ]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(payload.path()),
            payload_aarch64: None,
            host_binary: None,
            terminfo: Some(terminfo.path()),
        };

        let result = remote_install(&runner, &inputs).expect(
            "a terminfo failure must not fail the whole install: the session still works \
             remotely with TERM=xterm-256color",
        );
        assert_eq!(result.arch, RemoteArch::LinuxX86_64);
        assert!(
            result.terminfo_warning.is_some(),
            "expected a terminfo warning to be recorded in the summary"
        );
    }

    #[test]
    fn remote_install_without_terminfo_flag_skips_terminfo_steps_entirely() {
        let payload = tempfile::NamedTempFile::new().expect("create scratch payload file");
        let runner = RecordingRunner::scripted(vec![ok("Linux x86_64\n"), ok(""), ok("")]);
        let inputs = RemoteInstallInputs {
            host: "myhost",
            payload_x86_64: Some(payload.path()),
            payload_aarch64: None,
            host_binary: None,
            terminfo: None,
        };

        let result =
            remote_install(&runner, &inputs).expect("should succeed with no --terminfo given");
        assert_eq!(result.terminfo_warning, None);
        let calls = runner.calls.borrow();
        assert_eq!(
            calls.len(),
            3,
            "no terminfo step should run when --terminfo is absent, got {calls:?}"
        );
    }
}
