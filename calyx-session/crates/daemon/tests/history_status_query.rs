//! P6 RED2: `ControlMsg::GetHistoryEnabled` / `HistoryEnabled`, the
//! query half of the toggle `history_toggle.rs` already covers
//! (`SetHistoryEnabled` mutates; this queries without mutating). Added
//! so `calyx-session history status` has something to ask -- no query
//! message existed before this round (see
//! `crate::commands::history`'s own header on the CLI side for the
//! full P6 RED2 investigation note).
//!
//! `conn.rs`'s `GetHistoryEnabled` arm is currently `unimplemented!()`,
//! which panics on the daemon's per-connection thread instead of
//! replying. Since that panic never reaches this test's process
//! directly, every assertion below fails via `common::roundtrip`'s
//! bounded `IO_TIMEOUT` (3s) read timing out and returning `Err` --
//! the same indirect-but-bounded RED signal `history_toggle.rs` would
//! have relied on had `SetHistoryEnabled` itself been unimplemented.
//! This is expected, not a broken test: the daemon's per-connection
//! thread architecture has no other way to observe a stub panic from
//! across the socket.

mod common;

use proto::ControlMsg;

#[test]
fn get_history_enabled_reports_the_bind_time_default_off() {
    let daemon = common::ScratchDaemon::spawn();
    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);

    let reply = common::roundtrip(&control, &ControlMsg::GetHistoryEnabled)
        .expect("GetHistoryEnabled round-trip");
    assert_eq!(
        reply,
        ControlMsg::HistoryEnabled { enabled: false },
        "bind-time default is off (ScratchDaemon::spawn), and GetHistoryEnabled must report it"
    );
}

#[test]
fn get_history_enabled_reports_the_bind_time_default_on() {
    let daemon = common::ScratchDaemon::spawn_with_history_enabled();
    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);

    let reply = common::roundtrip(&control, &ControlMsg::GetHistoryEnabled)
        .expect("GetHistoryEnabled round-trip");
    assert_eq!(
        reply,
        ControlMsg::HistoryEnabled { enabled: true },
        "bind-time default is on (ScratchDaemon::spawn_with_history_enabled), and GetHistoryEnabled must \
         report it"
    );
}

#[test]
fn get_history_enabled_reflects_a_prior_set_without_being_the_one_that_changes_it() {
    let daemon = common::ScratchDaemon::spawn();
    let control = daemon.connect().expect("connect control stream");
    common::hello(&control);

    let set_reply = common::roundtrip(&control, &ControlMsg::SetHistoryEnabled { enabled: true })
        .expect("SetHistoryEnabled round-trip");
    assert_eq!(
        set_reply,
        ControlMsg::SetHistoryEnabledOk { enabled: true },
        "SetHistoryEnabled should reply with the value now in effect"
    );

    let first_query = common::roundtrip(&control, &ControlMsg::GetHistoryEnabled)
        .expect("first GetHistoryEnabled round-trip");
    assert_eq!(
        first_query,
        ControlMsg::HistoryEnabled { enabled: true },
        "GetHistoryEnabled must reflect the prior SetHistoryEnabled"
    );

    // A second, immediately repeated query must report the identical
    // value: querying must never itself flip the flag.
    let second_query = common::roundtrip(&control, &ControlMsg::GetHistoryEnabled)
        .expect("second GetHistoryEnabled round-trip");
    assert_eq!(
        second_query,
        ControlMsg::HistoryEnabled { enabled: true },
        "a second consecutive GetHistoryEnabled must not have changed anything"
    );
}
