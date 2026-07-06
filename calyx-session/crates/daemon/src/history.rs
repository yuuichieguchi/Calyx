//! Opt-in on-disk history persistence for session output.
//!
//! Wired into the session lifecycle by `session.rs`: `spawn_session`
//! captures the daemon-wide flag once at session creation, and the
//! session thread seeds from, appends to, and finally removes the
//! files described here.
//!
//! **Contract.** When enabled for a session (`DaemonConfig::history_enabled`
//! at session-creation time, or the live override installed by
//! `ControlMsg::SetHistoryEnabled`; see the daemon module doc), every
//! chunk of raw PTY output fed to that session's `vt::Terminal` is also
//! appended, byte-for-byte and in the same order, to
//! `state_dir/history/<id>.raw` (dir mode `0700`, file mode `0600`).
//! When disabled (the default: herdr parity, secrets caution), nothing
//! under `state_dir/history/` is ever created or touched for that
//! session.
//!
//! **Rotation.** `<id>.raw` (the *active* file) is capped at
//! `cap_bytes`: a write that would push it over the cap instead rotates
//! it to `<id>.raw.1` (replacing any previous `.1`) and starts a fresh
//! empty active file, so retained history is bounded at roughly
//! `2 * cap_bytes` total across the two files (mirrors the common
//! two-generation logrotate scheme rather than an in-place
//! truncate-front, which would require shifting file contents on every
//! write). The oldest bytes, everything before the current `.1` file,
//! are dropped once both files are full.
//!
//! **Cleanup.** History exists to survive a daemon *process* death, not
//! an individual session's own end: on any session teardown (killed or
//! exited normally) the daemon deletes that session's history file(s).
//! A leftover `<id>.raw`(`.1`) on disk therefore only ever means the
//! daemon process ended without running that teardown, i.e. a crash,
//! which is exactly the case `read_persisted` exists for: on session
//! *creation*, if a history file already exists for the requested id
//! (and history is enabled), its bytes are fed into the freshly created
//! `vt::Terminal` before the session's main loop starts reading from
//! the PTY, so a client attaching to the recreated session sees the
//! pre-crash scrollback in its `Replay` frame.
//!
//! **Seed-once-then-reset.** Right after the persisted bytes are fed
//! into the recreated session's terminal, the on-disk files are
//! deleted (`remove_all`) and the session's live appends start over
//! from an empty active file. The seed content lives on only inside
//! the terminal's scrollback; keeping it on disk as well while new
//! appends accumulate alongside would grow the record twice over (once
//! as the seed, once re-echoed by whatever the recreated session
//! prints), so the reset keeps "what is on disk" meaning exactly "what
//! this session's own PTY produced".
//!
//! Accepted experimental residual (P6 review H10): the delete happens
//! before the recreated session durably appends its first new byte, so
//! a *second* daemon crash in that narrow window (terminal seeded,
//! files already gone, nothing new written yet) loses the pre-first-crash
//! scrollback for good. The decision site in `session.rs` documents why
//! this is accepted rather than fixed by keeping the bytes until the
//! first append (it would change the file's per-generation meaning and
//! entangle this path with the rotation/cleanup contract).

use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Subdirectory of a daemon's `state_dir` holding per-session history
/// files.
const HISTORY_DIR_NAME: &str = "history";

/// Bind-time default rotation cap for a session's active history file
/// (see the module doc). Tests inject a much smaller value via
/// `HistoryWriter::open`'s `cap_bytes` parameter rather than relying on
/// this constant, so rotation is exercisable without writing tens of
/// megabytes.
pub(crate) const DEFAULT_CAP_BYTES: u64 = 10 * 1024 * 1024;

/// `state_dir/history`.
fn history_dir(state_dir: &Path) -> PathBuf {
    state_dir.join(HISTORY_DIR_NAME)
}

/// `state_dir/history/<id>.raw`: the active (currently being appended)
/// history file.
fn active_path(state_dir: &Path, id: &str) -> PathBuf {
    history_dir(state_dir).join(format!("{id}.raw"))
}

/// `state_dir/history/<id>.raw.1`: the previous rotation, if any.
fn rotated_path(state_dir: &Path, id: &str) -> PathBuf {
    history_dir(state_dir).join(format!("{id}.raw.1"))
}

/// Opens (creating at mode `0600` if needed) an active history file
/// for appending. `mode(0o600)` only applies at creation and is
/// filtered through the process umask (and a pre-existing file keeps
/// whatever mode it had), so the mode is enforced explicitly after the
/// open.
fn open_active_file(path: &Path) -> io::Result<fs::File> {
    let file = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

/// Appends a live session's raw PTY output to its on-disk history file,
/// rotating once the active file would exceed `cap_bytes`. See the
/// module doc for the on-disk layout and rotation scheme.
pub(crate) struct HistoryWriter {
    state_dir: PathBuf,
    id: String,
    cap_bytes: u64,
    /// Current size of the active (`<id>.raw`) file; tracked here
    /// rather than re-`stat`-ing on every `append` call.
    active_len: u64,
    /// The open active file, held across appends so the hot path is a
    /// single `write` rather than an open/write/close per PTY chunk.
    file: fs::File,
}

impl HistoryWriter {
    /// Opens (creating `state_dir/history` at mode `0700` and the
    /// active file at mode `0600` if they don't already exist) the
    /// history writer for session `id`. Opens in append mode rather
    /// than truncating: in the wired create path the caller has
    /// already consumed and reset any leftover crash record
    /// (seed-once-then-reset, see the module doc), so the active file
    /// normally starts empty here, and appending merely avoids
    /// destroying data if that ever ceases to hold.
    pub(crate) fn open(state_dir: &Path, id: &str, cap_bytes: u64) -> io::Result<HistoryWriter> {
        let dir = history_dir(state_dir);
        if !dir.exists() {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true).mode(0o700);
            builder.create(&dir)?;
            // `mode(0o700)` is filtered through the process umask;
            // enforce the exact mode the contract promises.
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        }
        let file = open_active_file(&active_path(state_dir, id))?;
        let active_len = file.metadata()?.len();
        Ok(HistoryWriter {
            state_dir: state_dir.to_path_buf(),
            id: id.to_string(),
            cap_bytes,
            active_len,
            file,
        })
    }

    /// Appends `bytes` to the active history file, rotating first if
    /// the write would push it over `cap_bytes` (only when the active
    /// file already has content: a single write larger than the cap on
    /// its own is still written in full rather than silently
    /// truncated, since preserving a full session output invariant
    /// matters more than never overshooting on an isolated oversized
    /// burst).
    pub(crate) fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        if self.active_len > 0 && self.active_len + bytes.len() as u64 > self.cap_bytes {
            self.rotate()?;
        }
        self.file.write_all(bytes)?;
        self.active_len += bytes.len() as u64;
        Ok(())
    }

    /// Renames the active file to `<id>.raw.1` (atomically replacing
    /// any previous rotation) and starts a fresh empty active file.
    fn rotate(&mut self) -> io::Result<()> {
        let active = active_path(&self.state_dir, &self.id);
        fs::rename(&active, rotated_path(&self.state_dir, &self.id))?;
        self.file = open_active_file(&active)?;
        self.active_len = 0;
        Ok(())
    }

    /// Deletes both `<id>.raw` and `<id>.raw.1` for `id`, if present.
    /// Called on session teardown (kill or normal exit alike: history
    /// exists to survive a daemon crash, not an individual session's
    /// own end; see the module doc). Missing files are not an error.
    pub(crate) fn remove_all(state_dir: &Path, id: &str) -> io::Result<()> {
        for path in [active_path(state_dir, id), rotated_path(state_dir, id)] {
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

/// Whether any history is persisted on disk for `id` (either
/// generation). Live Handoff adoption (`crate::handoff::adopt_session`)
/// uses this as the session's creation-time history flag made durable:
/// a session that was persisting under the previous daemon generation
/// keeps persisting (the writer appends to the surviving file), one
/// that was not stays off, regardless of the receiving daemon's own
/// daemon-wide default.
pub(crate) fn has_persisted(state_dir: &Path, id: &str) -> bool {
    active_path(state_dir, id).exists() || rotated_path(state_dir, id).exists()
}

/// Reads back whatever history is currently persisted on disk for
/// `id`: `None` if neither `<id>.raw` nor `<id>.raw.1` exists, else the
/// rotated file's bytes (oldest) followed by the active file's bytes
/// (newest), concatenated in chronological order. That is the same
/// order the bytes were originally fed to the session's
/// `vt::Terminal`, so feeding the result into a fresh terminal
/// reconstructs pre-crash scrollback (see the module doc's
/// crash-restore contract).
pub(crate) fn read_persisted(state_dir: &Path, id: &str) -> io::Result<Option<Vec<u8>>> {
    let mut combined = Vec::new();
    let mut found = false;
    for path in [rotated_path(state_dir, id), active_path(state_dir, id)] {
        match fs::read(&path) {
            Ok(bytes) => {
                found = true;
                combined.extend_from_slice(&bytes);
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    Ok(found.then_some(combined))
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    /// R3 (P6 RED, rotation): with a small injected cap, writing well
    /// past `2 * cap_bytes` of distinguishable content must never let
    /// the active file exceed `cap_bytes`, and the earliest-written
    /// content must eventually be evicted from both on-disk files,
    /// proving rotation actually drops old bytes rather than growing
    /// `<id>.raw` without bound.
    #[test]
    fn append_rotates_before_the_active_file_exceeds_the_cap() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let id = "01J-p6-rotation-test";
        const CAP_BYTES: u64 = 4096;
        // One write per "line", each individually well under the cap,
        // so rotation is driven by cumulative size rather than any
        // single oversized write.
        const LINE_LEN: usize = 64;
        // Comfortably more than 2 * CAP_BYTES worth of writes, so at
        // least one full rotation (and then some) must have happened.
        const LINES: usize = (3 * CAP_BYTES as usize) / LINE_LEN;

        let mut writer = HistoryWriter::open(tmp.path(), id, CAP_BYTES)
            .expect("HistoryWriter::open should succeed");

        let first_marker = "FIRST_LINE_MARKER";
        let last_marker = "LAST_LINE_MARKER";
        for i in 0..LINES {
            let marker = if i == 0 {
                first_marker
            } else if i == LINES - 1 {
                last_marker
            } else {
                "x"
            };
            let mut line = format!("{marker}-{i:06}").into_bytes();
            line.resize(LINE_LEN, b'.');
            line.push(b'\n');
            writer.append(&line).expect("append should succeed");
        }

        let active_path = active_path(tmp.path(), id);
        let active_len = fs::metadata(&active_path)
            .expect("active history file should exist after writes")
            .len();
        assert!(
            active_len <= CAP_BYTES,
            "active history file must never exceed the {CAP_BYTES}-byte cap, got {active_len} \
             bytes"
        );

        let rotated_path = rotated_path(tmp.path(), id);
        if let Ok(meta) = fs::metadata(&rotated_path) {
            assert!(
                meta.len() <= CAP_BYTES,
                "rotated history file must never exceed the {CAP_BYTES}-byte cap, got {} bytes",
                meta.len()
            );
        }

        let mut combined = fs::read(&rotated_path).unwrap_or_default();
        combined.extend(fs::read(&active_path).expect("read active history file"));
        let combined_text = String::from_utf8_lossy(&combined);
        assert!(
            !combined_text.contains(first_marker),
            "after writing well past 2x the cap, the earliest-written content should have been \
             rotated out of both on-disk files, got: {combined_text:?}"
        );
        assert!(
            combined_text.contains(last_marker),
            "the most recently written content must still be present on disk, got: \
             {combined_text:?}"
        );
    }

    /// R5 unit half (P6 RED, crash-restore seed): `read_persisted`
    /// concatenates the rotated file (oldest) before the active file
    /// (newest), and feeding that concatenation into a *fresh*
    /// `vt::Terminal` reconstructs both halves' content in the right
    /// relative order. That is exactly the operation `spawn_session`
    /// will perform on session creation when a leftover history file
    /// indicates the daemon crashed rather than this session cleanly
    /// ending (see the module doc).
    ///
    /// The full daemon-restart path (recreating a session after a
    /// simulated crash and asserting the client's `Replay` frame
    /// contains pre-crash content) is exercised separately as an
    /// integration test; see
    /// `crates/daemon/tests/history_crash_restore.rs`, which documents
    /// this same decomposition.
    #[test]
    fn read_persisted_concatenates_rotated_then_active_and_seeds_a_fresh_terminal() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let id = "01J-p6-seed-unit-test";
        let dir = history_dir(tmp.path());
        fs::create_dir_all(&dir).expect("create scratch history dir");

        fs::write(rotated_path(tmp.path(), id), b"OLDEST_MARKER line\r\n")
            .expect("write scratch rotated history file");
        fs::write(active_path(tmp.path(), id), b"NEWEST_MARKER line\r\n")
            .expect("write scratch active history file");

        let persisted = read_persisted(tmp.path(), id)
            .expect("read_persisted should succeed")
            .expect("read_persisted should find the history files written above");
        let persisted_text = String::from_utf8_lossy(&persisted);
        assert!(
            persisted_text.starts_with("OLDEST_MARKER"),
            "read_persisted must return the rotated (oldest) file's bytes first, got: \
             {persisted_text:?}"
        );
        let oldest_pos = persisted_text
            .find("OLDEST_MARKER")
            .expect("OLDEST_MARKER should be present");
        let newest_pos = persisted_text
            .find("NEWEST_MARKER")
            .expect("NEWEST_MARKER should be present");
        assert!(
            oldest_pos < newest_pos,
            "the rotated file's content must precede the active file's content, got: \
             {persisted_text:?}"
        );

        let mut terminal =
            vt::Terminal::new(80, 24, 8 * 1024 * 1024).expect("create scratch terminal");
        terminal
            .feed(&persisted)
            .expect("feeding persisted history into a fresh terminal should succeed");
        let dump = terminal.dump_text().expect("dump_text after seeding");
        assert!(
            dump.contains("OLDEST_MARKER"),
            "a terminal seeded with read_persisted's bytes should contain the oldest content, \
             got: {dump:?}"
        );
        assert!(
            dump.contains("NEWEST_MARKER"),
            "a terminal seeded with read_persisted's bytes should contain the newest content, \
             got: {dump:?}"
        );
    }

    /// R1 support: disabled history must never create even the
    /// `history/` directory, let alone a file in it. Checked here as a
    /// pure filesystem invariant (the daemon-level integration
    /// contract lives in
    /// `crates/daemon/tests/history_default_off.rs`). This does not
    /// call any stub, so it passes today; it stays green as a
    /// permanent regression guard once `spawn_session` starts
    /// constructing `HistoryWriter`s conditionally.
    #[test]
    fn history_dir_path_is_a_subdirectory_of_state_dir_and_not_created_by_computing_it() {
        let tmp = tempfile::tempdir().expect("create scratch state dir");
        let dir = history_dir(tmp.path());
        assert_eq!(dir, tmp.path().join("history"));
        assert!(
            !dir.exists(),
            "merely computing the history directory path must not create it"
        );
    }
}
