//! Control-channel message types, carried as CBOR inside
//! [`crate::FrameType::Control`] frames.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::error::ProtoError;

/// Wire protocol version negotiated by [`ControlMsg::Hello`] /
/// [`ControlMsg::HelloOk`]. Bump whenever a breaking change is made to
/// `ControlMsg` or the framing layer.
pub const PROTOCOL_VERSION: u32 = 1;

/// A request or response on the control channel. Serialized as CBOR via
/// [`encode_control`]/[`decode_control`] and carried inside
/// [`crate::FrameType::Control`] frames.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ControlMsg {
    /// First message a client sends after connecting.
    Hello {
        version: u32,
    },
    /// Sent in reply to `Hello` when `version` matches
    /// [`PROTOCOL_VERSION`].
    HelloOk {
        version: u32,
    },
    /// Sent in reply to `Hello` when `version` does not match; the
    /// connection should be closed after this.
    HelloErr {
        reason: String,
    },
    /// Requests the live session list (running sessions only).
    List,
    ListOk {
        sessions: Vec<SessionInfo>,
    },
    /// Requests the full ledger-backed session list, including exited
    /// sessions with their exit code (unlike `List`, which only
    /// reports the live registry). Added for P4's resume flow, which
    /// needs to know how a session it isn't attached to ended.
    ListAll,
    ListAllOk {
        sessions: Vec<SessionInfo>,
    },
    /// Creates a new session from `spec` without attaching to it.
    New {
        spec: SessionSpec,
    },
    NewOk {
        info: SessionInfo,
    },
    /// Attaches this connection to session `id`, optionally creating it
    /// first from `create` if it does not exist (idempotent: a second
    /// `Attach` with the same `id` and `create` set attaches to the
    /// existing session rather than spawning another). `cols`/`rows`
    /// give this client's initial terminal size.
    Attach {
        id: String,
        create: Option<SessionSpec>,
        cols: u16,
        rows: u16,
    },
    /// Reply to `Attach`. A `crate::FrameType::Replay` frame carrying the
    /// session's current state precedes this connection's first
    /// `crate::FrameType::Output` frame; see the module-level daemon
    /// contract for the exact ordering.
    AttachOk {
        info: SessionInfo,
    },
    /// Detaches this connection from its session without killing it.
    Detach,
    /// Kills session `id` (and its child process).
    Kill {
        id: String,
    },
    KillOk,
    MetaSet {
        id: String,
        key: String,
        value: String,
    },
    MetaGet {
        id: String,
    },
    MetaOk {
        meta: BTreeMap<String, String>,
    },
    /// Resizes the session this connection is attached to. Carries no
    /// `id`: it always targets the single session the sending
    /// connection is currently attached to.
    Resize {
        cols: u16,
        rows: u16,
    },
    /// Enables or disables on-disk history persistence daemon-wide,
    /// effective immediately for any session *created* after this
    /// message is processed. Sessions already running keep whatever was
    /// in effect when they were created (see the daemon module doc for
    /// the full history-persistence contract): this only changes what
    /// new sessions inherit, never anything already in flight. The
    /// daemon also has a bind-time default (`DaemonConfig::history_enabled`,
    /// e.g. from a `--persist-history` CLI flag), which seeds the value
    /// this message subsequently overrides for the rest of the daemon's
    /// process lifetime.
    SetHistoryEnabled {
        enabled: bool,
    },
    /// Reply to `SetHistoryEnabled`, echoing the value now in effect.
    SetHistoryEnabledOk {
        enabled: bool,
    },
    /// Queries the daemon-wide history-persistence default currently in
    /// effect (see `SetHistoryEnabled`'s doc comment for the full
    /// contract), without mutating it. Added for the CLI's `history
    /// status` subcommand (P6 RED2): `SetHistoryEnabled`/`SetHistoryEnabledOk`
    /// existed before this with no way for a client to observe the
    /// current value without also setting it.
    GetHistoryEnabled,
    /// Reply to `GetHistoryEnabled`, carrying the value now in effect.
    /// Never sent unprompted (unlike `Event`).
    HistoryEnabled {
        enabled: bool,
    },
    /// (EXPERIMENTAL) Asks the daemon to open its dedicated Live
    /// Handoff endpoint (a raw fd-passing Unix socket, deliberately
    /// separate from this framed control channel; see the daemon
    /// crate's `handoff` module doc) for exactly one bounded-timeout
    /// receiver connection. Sent by `calyx-session upgrade` before it
    /// spawns the new daemon process. After the `PrepareHandoffOk`
    /// reply, this connection reports the outcome: on handoff success
    /// the daemon process exits (the connection just drops, like a
    /// crash); on failure a `handoff-failed` `Err` arrives and the
    /// daemon keeps serving unchanged.
    PrepareHandoff,
    /// Reply to `PrepareHandoff`, carrying the filesystem path of the
    /// handoff endpoint the receiver must connect to
    /// (`<runtime_dir>/handoff.sock`).
    PrepareHandoffOk {
        path: String,
    },
    /// Server-pushed notification, unprompted by any client request.
    Event(SessionEvent),
    /// Generic error reply to any of the above.
    Err {
        code: String,
        msg: String,
    },
}

/// A server-pushed event not requested by any specific `ControlMsg`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SessionEvent {
    /// The session's child process exited with `code`.
    Exited { id: String, code: i32 },
}

/// Describes a session to be created, via `ControlMsg::New` or
/// `ControlMsg::Attach { create: Some(spec), .. }`.
///
/// `id` is caller-supplied (generated as a ULID string by the CLI before
/// sending) rather than server-assigned, so that `Attach { create, .. }`
/// can be idempotent: retrying with the same `id` always targets the
/// same session instead of racing a second one into existence.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionSpec {
    pub id: String,
    pub name: Option<String>,
    pub cwd: Option<String>,
    /// `None` means "daemon default" (the user's login shell).
    pub argv: Option<Vec<String>>,
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

/// A session's current state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionState {
    Running,
    Exited { code: i32 },
}

/// A session as reported by `ListOk`, `NewOk`, and `AttachOk`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub name: Option<String>,
    pub cwd: Option<String>,
    pub state: SessionState,
    pub created_at_ms: u64,
    pub attached_clients: u32,
    /// The child process's pid while `state` is `Running` (unspecified,
    /// but conventionally `0`, once `Exited`). Added beyond the P2 spec's
    /// original field list because the kill-verification test needs a
    /// way to confirm the OS process is actually gone (`kill -0`), which
    /// isn't otherwise observable through the protocol.
    pub pid: u32,
    pub meta: BTreeMap<String, String>,
    /// Wall-clock time (Unix epoch ms) this record's `state` last
    /// flipped to `Exited`; `None` while `Running`. Also `None` for a
    /// ledger record written by a daemon build that predates this
    /// field, which the ledger's retention GC (`daemon::ledger::gc`)
    /// treats as already past its retention window rather than kept
    /// forever, since such a record cannot be freshly exited (`#[serde(default)]`
    /// is redundant for an `Option` field under serde's own derive, but
    /// spelled out here so the "old ledger files keep loading" contract
    /// this field must uphold is not left implicit).
    #[serde(default)]
    pub exited_at_ms: Option<u64>,
}

/// Encodes a `ControlMsg` to CBOR bytes suitable for a
/// [`crate::FrameType::Control`] frame's payload.
pub fn encode_control(msg: &ControlMsg) -> Result<Vec<u8>, ProtoError> {
    let mut buf = Vec::new();
    ciborium::into_writer(msg, &mut buf).map_err(|e| ProtoError::Cbor(e.to_string()))?;
    Ok(buf)
}

/// Decodes a [`crate::FrameType::Control`] frame's payload back into a
/// `ControlMsg`. Must return `Err(ProtoError::Cbor(_))` — never panic —
/// on truncated or malformed CBOR, since `bytes` comes from a socket a
/// client fully controls.
pub fn decode_control(bytes: &[u8]) -> Result<ControlMsg, ProtoError> {
    ciborium::from_reader(bytes).map_err(|e| ProtoError::Cbor(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// P6 (Live Handoff): the control-plane trigger for a handoff must
    /// round-trip through CBOR. Exercised per variant shape because
    /// CBOR encodes a unit enum variant and a struct enum variant
    /// differently (a bare string vs. a map), so one passing does not
    /// imply the other.
    #[test]
    fn prepare_handoff_round_trips_through_cbor() {
        let msg = ControlMsg::PrepareHandoff;
        let encoded = encode_control(&msg).expect("encode PrepareHandoff");
        let decoded = decode_control(&encoded).expect("decode PrepareHandoff");
        assert_eq!(decoded, msg);
    }

    /// See `prepare_handoff_round_trips_through_cbor`.
    #[test]
    fn prepare_handoff_ok_round_trips_through_cbor() {
        let msg = ControlMsg::PrepareHandoffOk {
            path: "/tmp/scratch-run/handoff.sock".to_string(),
        };
        let encoded = encode_control(&msg).expect("encode PrepareHandoffOk");
        let decoded = decode_control(&encoded).expect("decode PrepareHandoffOk");
        assert_eq!(decoded, msg);
    }
}
