//! Tests 17 and 18 (spec): `Terminal::set_responder`'s contract for
//! detached-mode query responses (DSR 6 cursor-position report here;
//! DA1/DECRQM are the same contract, not re-tested per-sequence).

use std::cell::RefCell;
use std::rc::Rc;

use vt::Terminal;

const SCROLLBACK_BYTES: u32 = 1024 * 1024;

#[test]
fn set_responder_receives_dsr6_cursor_position_report() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    // Move the cursor to a known, non-origin position before the query
    // so the reported coordinates can't pass by accident from a
    // default/zeroed cursor.
    t.feed(b"\x1b[5;10H")
        .expect("feed CUP to position the cursor");
    let (row, col) = t.cursor_pos().expect("cursor pos after CUP");
    assert_eq!(
        (row, col),
        (4, 9),
        "sanity: CUP 5;10 should be 0-indexed (4, 9)"
    );

    let received: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
    let received_in_closure = Rc::clone(&received);
    t.set_responder(move |bytes: &[u8]| {
        received_in_closure.borrow_mut().extend_from_slice(bytes);
    });

    t.feed(b"\x1b[6n")
        .expect("feed DSR 6 (cursor position report request)");

    let response = received.borrow().clone();
    let expected = format!("\x1b[{};{}R", row + 1, col + 1);
    assert_eq!(
        response,
        expected.into_bytes(),
        "responder should receive a CPR reply matching the 1-indexed cursor position"
    );
}

// ==================== P2 review item 11 ====================
//
// Query-class coverage beyond DSR 6: OSC 11 (background color query)
// and CSI ?u (kitty keyboard protocol query) must also produce a
// responder callback. DSR `?996` (color scheme) is deliberately not
// tested here: a real terminal that never requested dark/light
// notifications correctly stays silent to it, so "no response" is the
// right behavior there, not a bug.

#[test]
fn set_responder_receives_osc11_background_color_query_response() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");

    let received: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
    let received_in_closure = Rc::clone(&received);
    t.set_responder(move |bytes: &[u8]| {
        received_in_closure.borrow_mut().extend_from_slice(bytes);
    });

    t.feed(b"\x1b]11;?\x07")
        .expect("feed OSC 11 (background color query)");

    let response = received.borrow().clone();
    assert!(
        !response.is_empty(),
        "responder should receive an OSC 11 background-color reply, got no bytes at all"
    );
    let text = String::from_utf8_lossy(&response);
    assert!(
        text.starts_with("\u{1b}]11;"),
        "OSC 11 reply should start with the OSC 11 introducer, got {text:?}"
    );
}

#[test]
fn set_responder_receives_kitty_keyboard_query_response() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");

    let received: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
    let received_in_closure = Rc::clone(&received);
    t.set_responder(move |bytes: &[u8]| {
        received_in_closure.borrow_mut().extend_from_slice(bytes);
    });

    t.feed(b"\x1b[?u")
        .expect("feed CSI ?u (kitty keyboard protocol query)");

    let response = received.borrow().clone();
    assert!(
        !response.is_empty(),
        "responder should receive a kitty keyboard protocol reply, got no bytes at all"
    );
    let text = String::from_utf8_lossy(&response);
    assert!(
        text.starts_with("\u{1b}[?") && text.ends_with('u'),
        "kitty keyboard query reply should look like CSI ? <flags> u, got {text:?}"
    );
}

#[test]
fn feed_with_dsr6_and_no_responder_registered_does_not_panic() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    // No `set_responder` call at all: the query must be silently
    // ignored rather than panicking or erroring.
    let result = t.feed(b"\x1b[6n");
    assert!(
        result.is_ok(),
        "feed should tolerate a query sequence with no responder registered, got {result:?}"
    );
}
