//! Test 16 (spec): peer-uid verification code path exists and is
//! directly callable. Kept independent of the full daemon (no
//! `ScratchDaemon::spawn`/socket needed) since it only needs a
//! connected `UnixStream` pair to exercise `verify_peer_uid` directly.

use std::os::unix::net::UnixStream;

use daemon::peer::verify_peer_uid;

#[test]
fn verify_peer_uid_accepts_a_same_uid_connection() {
    let (a, _b) = UnixStream::pair().expect("create a connected UnixStream pair");
    // Both ends of a `UnixStream::pair()` are this same process, so
    // this is definitionally a same-uid connection.
    let result = verify_peer_uid(&a);
    assert!(
        result.is_ok(),
        "a same-process (same-uid) peer should be accepted, got {result:?}"
    );
}
