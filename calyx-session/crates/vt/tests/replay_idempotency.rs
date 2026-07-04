//! Integration tests for `vt::Terminal` replay idempotency.
//!
//! Core property under test: for a terminal A fed some fixture bytes,
//! `A.render_replay()` fed into a *blank* terminal B of the same size
//! must reproduce `A.dump_text()`, `A.cursor_pos()`, and `A.total_rows()`,
//! and re-describing both terminals via `render_replay()` again must
//! produce byte-identical output (catching state divergence, such as a
//! leaked SGR pen or charset, that plain-text dumps can't see).

use vt::Terminal;

const SCROLLBACK_BYTES: u32 = 8 * 1024 * 1024;

/// 200 lines of the form `Line 0000\r\n` .. `Line 0199\r\n`.
fn lines_200() -> Vec<u8> {
    let mut fixture = Vec::new();
    for i in 0..200 {
        fixture.extend_from_slice(format!("Line {i:04}\r\n").as_bytes());
    }
    fixture
}

/// Asserts the core replay-idempotency property for an already-prepared
/// terminal `a` (of size `cols`x`rows`): replaying onto a blank terminal
/// of the same size reproduces the visible+scrollback text, the cursor
/// position, the total row count, and (as a stronger check than any of
/// those individually) yields a terminal that describes itself via
/// `render_replay()` identically to the original. `label` identifies the
/// scenario under test in assertion failure messages (in place of a
/// single `fixture` byte slice, since callers may have built `a` via a
/// sequence of operations rather than one fixture).
fn assert_replay_idempotent_for(a: &mut Terminal, cols: u16, rows: u16, label: &str) {
    let replay = a.render_replay().expect("render replay from terminal A");

    let mut b = Terminal::new(cols, rows, SCROLLBACK_BYTES).expect("create terminal B");
    b.feed(&replay).expect("feed replay into terminal B");

    assert_eq!(
        a.dump_text().expect("dump text from terminal A"),
        b.dump_text().expect("dump text from terminal B"),
        "replay did not reproduce dump_text for {label}",
    );
    assert_eq!(
        a.cursor_pos().expect("cursor pos from terminal A"),
        b.cursor_pos().expect("cursor pos from terminal B"),
        "replay did not reproduce cursor_pos for {label}",
    );
    assert_eq!(
        a.total_rows().expect("total rows from terminal A"),
        b.total_rows().expect("total rows from terminal B"),
        "replay did not reproduce total_rows for {label}",
    );

    // Stronger than dump_text/cursor_pos/total_rows: a full state
    // divergence invisible to plain text (a leaked SGR pen, a leaked
    // charset designation, a mode that silently failed to re-apply)
    // still shows up once each terminal is asked to re-describe itself
    // as a replay sequence.
    let replay_from_a_again = a
        .render_replay()
        .expect("second render_replay from terminal A");
    let replay_from_b = b.render_replay().expect("render_replay from terminal B");
    assert_eq!(
        replay_from_a_again, replay_from_b,
        "regenerated replay diverged between A and B for {label}",
    );
}

/// Asserts the core replay-idempotency property for `fixture` fed into
/// a fresh `cols`x`rows` terminal. See `assert_replay_idempotent_for`
/// for the property being checked.
fn assert_replay_idempotent(fixture: &[u8], cols: u16, rows: u16) {
    let mut a = Terminal::new(cols, rows, SCROLLBACK_BYTES).expect("create terminal A");
    a.feed(fixture).expect("feed fixture into terminal A");
    assert_replay_idempotent_for(
        &mut a,
        cols,
        rows,
        &format!("fixture {:?}", String::from_utf8_lossy(fixture)),
    );
}

// ==================== 1. Plain text + cursor movement (CUP) ====================

#[test]
fn replay_idempotent_plain_text_with_cursor_movement() {
    // Two lines of plain text, then CUP (cursor position) back to
    // row 1 / col 1 and an overwrite of the first character.
    let fixture: &[u8] = b"Hello\r\nWorld\r\n\x1b[1;1HJ";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 2. SGR: 16-color / 256-color / truecolor / attrs ====================

#[test]
fn replay_idempotent_sgr_16_256_truecolor_and_attributes() {
    let fixture: &[u8] = b"\x1b[31mRed16\x1b[0m \
        \x1b[38;5;208mOrange256\x1b[0m \
        \x1b[38;2;10;200;30mTrueColor\x1b[0m \
        \x1b[1;4;7mBoldUnderlineReverse\x1b[0m\r\n";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 3. Full-width Japanese + emoji ====================

#[test]
fn replay_idempotent_fullwidth_japanese_and_emoji() {
    let fixture = "こんにちは 🎉 世界\r\n".as_bytes();
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 4. 200 lines at 80x24 (scrollback retention) ====================

#[test]
fn replay_idempotent_200_lines_retains_scrollback() {
    assert_replay_idempotent(&lines_200(), 80, 24);
}

#[test]
fn dump_text_after_200_lines_contains_scrolled_off_content() {
    // Distinct from the idempotency test above: confirms scrollback
    // itself (not just the visible 24 rows) is present in dump_text,
    // otherwise that test could pass vacuously by only comparing the
    // visible screen.
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.feed(&lines_200()).expect("feed 200 lines");
    let dump = t.dump_text().expect("dump text");
    assert!(
        dump.contains("Line 0000"),
        "dump_text should retain scrolled-off line 0, got: {dump:?}"
    );
    assert!(
        dump.contains("Line 0199"),
        "dump_text should contain the last written line, got: {dump:?}"
    );
}

// ==================== 5. Soft-wrapped long line ====================

#[test]
fn replay_idempotent_soft_wrapped_long_line() {
    // 200 non-whitespace characters with no line break: at 80 columns
    // this must soft-wrap across multiple screen rows.
    let fixture: Vec<u8> = (0..200u32).map(|i| b'a' + (i % 26) as u8).collect();
    assert_replay_idempotent(&fixture, 80, 24);
}

// ==================== 6. Alt screen entered and exited ====================

#[test]
fn replay_idempotent_alt_screen_entered_and_exited() {
    let fixture: &[u8] = b"primary before\r\n\
        \x1b[?1049h\x1b[2J\x1b[1;1Halt screen content\x1b[?1049l\
        primary after\r\n";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 7. Alt screen entered and left engaged ====================

#[test]
fn replay_idempotent_alt_screen_left_engaged() {
    // No trailing `?1049l`: the fixture ends while still in the alt
    // screen, so replay must include the mode-set sequence itself for
    // reconstruction to land back in the alt screen too.
    let fixture: &[u8] = b"primary before\r\n\x1b[?1049h\x1b[2J\x1b[1;1Hstill in alt screen";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 8. Mode reproduction (DECAWM off, bracketed paste, mouse) ====================

#[test]
fn replay_reproduces_decawm_bracketed_paste_and_mouse_modes() {
    // ?7l = DECAWM (autowrap) off, ?2004h = bracketed paste on,
    // ?1002h = mouse button-event tracking on.
    let fixture: &[u8] = b"\x1b[?7l\x1b[?2004h\x1b[?1002h";
    let mut a = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal A");
    a.feed(fixture).expect("feed mode-setting fixture");

    let replay = a.render_replay().expect("render replay");
    let replay_text = String::from_utf8_lossy(&replay);

    assert!(
        replay_text.contains("\u{1b}[?2004h"),
        "replay should re-set bracketed paste (2004), got: {replay_text:?}"
    );
    assert!(
        replay_text.contains("\u{1b}[?1002h"),
        "replay should re-set mouse button tracking (1002), got: {replay_text:?}"
    );
    assert!(
        replay_text.contains("\u{1b}[?7l"),
        "replay should re-clear DECAWM/autowrap (7), got: {replay_text:?}"
    );
}

// ==================== 9. Resize idempotency (80x24 -> 100x30) ====================

#[test]
fn replay_idempotent_after_resize() {
    let mut a = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal A");
    a.feed(b"before resize\r\n").expect("feed before resize");
    a.resize(100, 30).expect("resize terminal A");
    a.feed(b"after resize\r\n").expect("feed after resize");

    // B (created inside the helper) matches A's final (post-resize)
    // size, matching the "same-sized blank terminal" contract.
    assert_replay_idempotent_for(&mut a, 100, 30, "after resize from 80x24 to 100x30");
}

// ==================== 10. render_replay is non-destructive ====================

#[test]
fn render_replay_does_not_mutate_terminal_state() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.feed(b"Hello\r\nWorld\r\n\x1b[1;1HJ")
        .expect("feed fixture");

    let dump_before = t.dump_text().expect("dump text before replay");
    let cursor_before = t.cursor_pos().expect("cursor pos before replay");

    let replay_1 = t.render_replay().expect("first render_replay call");
    let replay_2 = t.render_replay().expect("second render_replay call");

    let dump_after = t.dump_text().expect("dump text after replay");
    let cursor_after = t.cursor_pos().expect("cursor pos after replay");

    assert_eq!(
        replay_1, replay_2,
        "render_replay should be deterministic across repeated calls"
    );
    assert_eq!(
        dump_before, dump_after,
        "render_replay must not mutate the terminal's visible state"
    );
    assert_eq!(
        cursor_before, cursor_after,
        "render_replay must not move the cursor"
    );
}

// ==================== 11. Origin mode with a scrolling region ====================

#[test]
fn replay_idempotent_origin_mode_with_scrolling_region() {
    // DECSTBM rows 3-10, then DECOM (origin mode) on, then CUP(2,2)
    // addressed relative to the scrolling region's top-left rather than
    // the screen's absolute origin.
    let fixture: &[u8] = b"\x1b[3;10r\x1b[?6h\x1b[2;2HX";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 12. DECCOLM mode ordering ====================

#[test]
fn replay_orders_deccolm_allow_before_deccolm_mode() {
    // ?40h = allow 80<->132 column switching, ?3h = DECCOLM (132-column
    // mode). ghostty-vt's mode table declares mode 3 ("132_column")
    // before mode 40 ("enable_mode_3"), so an implementation that
    // replays modes in table order re-sets ?3h before ?40h — a fresh
    // terminal then processes DECCOLM before switching is allowed and
    // silently drops it.
    let fixture: &[u8] = b"\x1b[?40h\x1b[?3hDECCOLM test\r\n";

    let mut a = Terminal::new(132, 24, SCROLLBACK_BYTES).expect("create terminal A");
    a.feed(fixture).expect("feed DECCOLM fixture");
    let replay = a.render_replay().expect("render replay from terminal A");
    let replay_text = String::from_utf8_lossy(&replay);

    let pos_40 = replay_text
        .find("\u{1b}[?40h")
        .expect("replay should re-set ?40h (allow column width switching)");
    let pos_3 = replay_text
        .find("\u{1b}[?3h")
        .expect("replay should re-set ?3h (DECCOLM)");
    assert!(
        pos_40 < pos_3,
        "replay must emit ?40h before ?3h so a fresh terminal honors \
         DECCOLM, got: {replay_text:?}"
    );

    assert_replay_idempotent(fixture, 132, 24);
}

// ==================== 13. Trailing blank lines' scrollback depth ====================

#[test]
fn replay_idempotent_trailing_blank_lines_scrollback_depth() {
    // A single content line followed by ten blank lines: exercises how
    // many *blank* rows survive into scrollback, a count that can drift
    // between terminals without any visible content difference — hence
    // asserting on `total_rows` rather than `dump_text` alone.
    let mut fixture = b"X\r\n".to_vec();
    for _ in 0..10 {
        fixture.extend_from_slice(b"\r\n");
    }
    assert_replay_idempotent(&fixture, 80, 5);
}

// ==================== 14. Alt screen does not leak the primary screen's pen ====================

#[test]
fn replay_idempotent_alt_screen_does_not_leak_primary_screen_pen() {
    // Sets an SGR pen (red) on the primary screen, enters the alt
    // screen, resets the pen, then writes text: the alt screen's "X"
    // must render with default attributes. A pen leak is invisible to
    // dump_text (which carries no styling) but shows up as a diverging
    // SGR sequence when both terminals regenerate their replay.
    let fixture: &[u8] = b"\x1b[31m\x1b[?1049h\x1b[0mX";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 15. Alt screen does not leak the primary screen's charset ====================

#[test]
fn replay_idempotent_alt_screen_does_not_leak_primary_screen_charset() {
    // Designates G0 as DEC Special Graphics on the primary screen,
    // enters the alt screen, resets G0 to ASCII, then prints "x_y".
    // 'x' (0x78) is inside the DEC Special Graphics remap range and
    // renders as U+2502 ('│') under that charset; on the source
    // terminal it must render as the literal ASCII 'x' instead, since
    // G0 was reset to ASCII before printing. If charset state leaks
    // across the primary/alt switch during replay, the target renders
    // 'x' as the box-drawing glyph, diverging from the source's
    // dump_text.
    let fixture: &[u8] = b"\x1b(0\x1b[?1049h\x1b(Bx_y";
    assert_replay_idempotent(fixture, 80, 24);
}

// ==================== 16. Mouse mode last-write-wins ordering ====================

#[test]
fn replay_reissues_last_write_wins_mouse_mode_last() {
    // ?1002h (button-event tracking) then ?1000h (normal tracking):
    // both set independent "was this ever requested" bits in
    // ghostty-vt's mode table, but they drive a single mutually
    // exclusive `flags.mouse_event` field where the *last* SET wins.
    // ghostty-vt's mode table declares mode 1000 before mode 1002, so
    // an implementation that replays modes in table order re-sets
    // ?1000h before ?1002h — the opposite of what actually won on the
    // source terminal.
    let fixture: &[u8] = b"\x1b[?1002h\x1b[?1000h";
    let mut a = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal A");
    a.feed(fixture).expect("feed mouse-mode fixture");

    let replay = a.render_replay().expect("render replay");
    let replay_text = String::from_utf8_lossy(&replay);

    let pos_1002 = replay_text
        .find("\u{1b}[?1002h")
        .expect("replay should mention ?1002h");
    let pos_1000 = replay_text
        .find("\u{1b}[?1000h")
        .expect("replay should mention ?1000h");
    assert!(
        pos_1002 < pos_1000,
        "replay must re-set ?1000h after ?1002h to preserve last-write-wins \
         mouse tracking, got: {replay_text:?}"
    );
}

// ==================== 17. Byte-budget effectiveness ====================

#[test]
fn small_byte_budget_evicts_oldest_scrollback_lines() {
    // A 4096-byte scrollback budget cannot hold 200 lines at 80
    // columns; the earliest lines must be evicted from dump_text.
    let mut t = Terminal::new(80, 24, 4096).expect("create terminal");
    t.feed(&lines_200()).expect("feed 200 lines");
    let dump = t.dump_text().expect("dump text");
    assert!(
        !dump.contains("Line 0000"),
        "a 4096-byte scrollback budget should have evicted the earliest \
         lines, got: {dump:?}"
    );
}

// ==================== Additional unit tests ====================

#[test]
fn terminal_new_succeeds_with_valid_dimensions() {
    let terminal = Terminal::new(80, 24, SCROLLBACK_BYTES);
    assert!(
        terminal.is_ok(),
        "Terminal::new(80, 24, {SCROLLBACK_BYTES}) should succeed, got {terminal:?}"
    );
}

#[test]
fn cursor_pos_after_feed_reflects_written_text() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.feed(b"Hello").expect("feed plain text");
    // 0-indexed (row, col): still on the first row, five columns in
    // from writing 5 characters with no wrap/newline.
    assert_eq!(t.cursor_pos().unwrap(), (0, 5));
}

#[test]
fn feed_with_invalid_utf8_does_not_panic() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    // A lone continuation byte (0x80) and an overlong two-byte encoding
    // of '/' (0xC0 0xAF): neither is valid UTF-8, but `feed` takes a
    // raw byte stream and must tolerate garbage without panicking.
    let invalid: &[u8] = &[0x48, 0x69, 0x80, 0xC0, 0xAF, 0x0D, 0x0A];
    let result = t.feed(invalid);
    assert!(
        result.is_ok(),
        "feed should tolerate invalid UTF-8 bytes without erroring, got {result:?}"
    );
}
