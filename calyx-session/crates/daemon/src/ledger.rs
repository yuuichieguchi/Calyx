//! The on-disk session ledger: `state_dir/sessions.json`, mode 0600,
//! written atomically (temp file + rename) on every registry change.
//!
//! The ledger is a persistence record, not a mirror of the live
//! registry: exited sessions stay in it (with their final state) so a
//! later daemon generation can still see them, which is also why `load`
//! seeds the map from any file a previous daemon left behind.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use proto::SessionInfo;

const LEDGER_FILE: &str = "sessions.json";

pub(crate) fn load(state_dir: &Path) -> BTreeMap<String, SessionInfo> {
    let path = state_dir.join(LEDGER_FILE);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => return BTreeMap::new(),
    };
    match serde_json::from_slice::<Vec<SessionInfo>>(&bytes) {
        Ok(sessions) => sessions
            .into_iter()
            .map(|info| (info.id.clone(), info))
            .collect(),
        Err(e) => {
            // A corrupt ledger is not worth refusing to start over; the
            // old contents are kept on disk until the first state
            // change overwrites them.
            eprintln!(
                "calyx-sessiond: ignoring unparseable ledger {}: {e}",
                path.display()
            );
            BTreeMap::new()
        }
    }
}

pub(crate) fn write(state_dir: &Path, sessions: &[SessionInfo]) -> io::Result<()> {
    // The state dir can vanish under a live daemon (wiped by a user or,
    // in tests, a scratch dir torn down around a "restart"); persisting
    // the in-memory ledger matters more than preserving the missing
    // directory as a signal, so recreate it.
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(state_dir)?;

    let json = serde_json::to_vec_pretty(&sessions)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    let path = state_dir.join(LEDGER_FILE);
    let tmp = state_dir.join(".sessions.json.tmp");
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&json)?;
        file.sync_all()?;
    }
    // 0600 explicitly in case the temp file predated this write with
    // other permissions (mode() only applies on creation).
    fs::set_permissions(&tmp, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    fs::rename(&tmp, &path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression test (P2 review bug #8): a ledger written by a newer
    /// daemon generation (carrying a field this build doesn't know
    /// about) must still load, preserving every session this build
    /// *does* understand — not silently drop to an empty ledger the
    /// way a swallowed deserialize error currently would.
    #[test]
    fn load_tolerates_an_unknown_extra_field() {
        let dir = tempfile::tempdir().expect("create scratch state dir");
        let json = r#"[{
            "id": "01J-p2-ledger-compat-1",
            "name": null,
            "cwd": null,
            "state": "Running",
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 123,
            "meta": {},
            "future_field_from_a_newer_daemon": "some-value"
        }]"#;
        fs::write(dir.path().join(LEDGER_FILE), json).expect("write scratch ledger");

        let loaded = load(dir.path());
        let info = loaded
            .get("01J-p2-ledger-compat-1")
            .expect("load should preserve a session despite an unknown extra field, not drop it");
        assert_eq!(info.pid, 123);
    }

    /// Regression test (P2 review bug #8, second half): a ledger
    /// predating some currently-optional field (modeled here by
    /// omitting `name`'s key entirely, not just sending it as `null`)
    /// must still load with that field defaulting to `None` — the same
    /// treatment a *future* optional field addition would need for
    /// old ledger data to keep loading.
    #[test]
    fn load_tolerates_an_optional_field_missing_entirely() {
        let dir = tempfile::tempdir().expect("create scratch state dir");
        let json = r#"[{
            "id": "01J-p2-ledger-compat-2",
            "cwd": null,
            "state": "Running",
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 456,
            "meta": {}
        }]"#;
        fs::write(dir.path().join(LEDGER_FILE), json).expect("write scratch ledger");

        let loaded = load(dir.path());
        let info = loaded.get("01J-p2-ledger-compat-2").expect(
            "load should preserve a session even when an Option field's key is \
             missing entirely (defaulting to None), or a future optional field \
             addition would break parsing of ledger data written before it existed",
        );
        assert_eq!(info.name, None);
    }
}
