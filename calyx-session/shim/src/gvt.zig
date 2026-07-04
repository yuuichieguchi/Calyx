//! libgvt: C ABI shim exposing a narrow slice of ghostty-vt's Terminal
//! to the `vt-sys` Rust crate.
//!
//! Error contract at the C boundary: fallible functions return 0 on
//! success and a negative code on failure; Zig errors never cross as
//! errors or unwinding. A Zig panic (a bug, not an expected path) is
//! routed through the root panic handler below: it writes the message
//! to stderr and aborts the process instead of unwinding into Rust.

const std = @import("std");
const vt = @import("ghostty-vt");

/// Controlled abort for panics inside the shim or ghostty-vt. Unwinding
/// across the C boundary into Rust would be undefined behavior, so the
/// process dies loudly and predictably instead.
pub const panic = std.debug.FullPanic(gvtPanic);

fn gvtPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    const stderr = std.posix.STDERR_FILENO;
    _ = std.posix.write(stderr, "libgvt panic: ") catch {};
    _ = std.posix.write(stderr, msg) catch {};
    _ = std.posix.write(stderr, "\n") catch {};
    std.posix.abort();
}

/// All shim allocations (terminal, streams, out-buffers) use the C
/// allocator so buffers handed to the Rust side can be released by
/// `gvt_buffer_free` without threading an allocator handle through
/// the ABI.
const alloc = std.heap.c_allocator;

/// Negative return codes for the C ABI. Values mirror negated POSIX
/// errno numbers so they read sensibly in logs, without claiming real
/// errno semantics.
const err_invalid: i32 = -22;
const err_nomem: i32 = -12;
/// The VT stream rejected fed bytes for a reason other than allocation
/// failure (mirrors -EPROTO). Kept in sync with `STREAM_ERROR_CODE` in
/// crates/vt/src/error.rs.
const err_stream: i32 = -71;

/// Opaque handle backing `void*` on the C side.
const GvtTerminal = struct {
    terminal: vt.Terminal,

    /// Owns the VT parser state. Its handler holds a pointer to
    /// `terminal` above, so a GvtTerminal must stay at its heap address
    /// for its whole lifetime (never copied by value).
    stream: vt.ReadonlyStream,

    /// The caller's scrollback byte budget. ghostty-vt receives the
    /// same value but only prunes at whole-page granularity, and one
    /// standard page holds hundreds of rows at typical widths, so the
    /// shim enforces the budget row-wise via `enforceScrollbackBudget`.
    max_scrollback_bytes: u32,

    /// Responder registration for detached-mode queries (P2). Stored
    /// but never invoked in P1: ReadonlyStream ignores query actions.
    responder_ctx: ?*anyopaque = null,
    responder: ?gvt_responder_fn = null,

    /// Trims the oldest history rows once the scrollback exceeds the
    /// byte budget, approximating each row's cost by its cell array
    /// plus row header at the current width (styles and grapheme data
    /// are not counted). Recomputed per call so it tracks resizes.
    fn enforceScrollbackBudget(self: *GvtTerminal) void {
        const primary = self.terminal.screens.get(.primary) orelse return;
        const row_bytes = @as(usize, self.terminal.cols) * @sizeOf(vt.Cell) +
            @sizeOf(vt.page.Row);
        const budget_rows = self.max_scrollback_bytes / row_bytes;
        const history = primary.pages.total_rows -| @as(usize, self.terminal.rows);
        if (history <= budget_rows) return;
        const excess = history - budget_rows;
        primary.eraseRows(
            .{ .history = .{} },
            .{ .history = .{ .y = @intCast(excess - 1) } },
        );
    }
};

fn fromHandle(t: ?*anyopaque) ?*GvtTerminal {
    return @ptrCast(@alignCast(t orelse return null));
}

/// Caller-provided out-buffer pair, validated and zeroed up front so
/// every error path leaves it in a defined empty state.
const OutBuf = struct {
    ptr: *?[*]u8,
    len: *usize,

    fn init(out_ptr: ?*?[*]u8, out_len: ?*usize) ?OutBuf {
        const op = out_ptr orelse return null;
        const ol = out_len orelse return null;
        op.* = null;
        ol.* = 0;
        return .{ .ptr = op, .len = ol };
    }

    fn set(self: OutBuf, buf: []u8) void {
        self.ptr.* = buf.ptr;
        self.len.* = buf.len;
    }
};

pub export fn gvt_terminal_new(
    cols: u16,
    rows: u16,
    max_scrollback_bytes: u32,
) callconv(.c) ?*anyopaque {
    if (cols == 0 or rows == 0) return null;

    const self = alloc.create(GvtTerminal) catch return null;

    const terminal = vt.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        // Passed through as-is: ghostty-vt's own unit for scrollback
        // is a byte budget.
        .max_scrollback = max_scrollback_bytes,
    }) catch {
        alloc.destroy(self);
        return null;
    };

    self.* = .{
        .terminal = terminal,
        .stream = undefined,
        .max_scrollback_bytes = max_scrollback_bytes,
    };
    self.stream = self.terminal.vtStream();
    return self;
}

pub export fn gvt_terminal_free(t: ?*anyopaque) callconv(.c) void {
    const self = fromHandle(t) orelse return;
    self.stream.deinit();
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub export fn gvt_terminal_feed(
    t: ?*anyopaque,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) i32 {
    const self = fromHandle(t) orelse return err_invalid;
    if (len == 0) return 0;
    const b = bytes orelse return err_invalid;
    self.stream.nextSlice(b[0..len]) catch |err| return switch (err) {
        error.OutOfMemory => err_nomem,
        else => err_stream,
    };
    self.enforceScrollbackBudget();
    return 0;
}

pub export fn gvt_terminal_resize(
    t: ?*anyopaque,
    cols: u16,
    rows: u16,
) callconv(.c) i32 {
    const self = fromHandle(t) orelse return err_invalid;
    if (cols == 0 or rows == 0) return err_invalid;
    self.terminal.resize(alloc, cols, rows) catch return err_nomem;
    self.enforceScrollbackBudget();
    return 0;
}

/// Re-attach replay sequence (rebuilds this terminal's state on a blank
/// same-sized terminal). Buffer ownership passes to the caller, who must
/// release it via `gvt_buffer_free`.
pub export fn gvt_render_replay(
    t: ?*anyopaque,
    out_ptr: ?*?[*]u8,
    out_len: ?*usize,
) callconv(.c) i32 {
    const out = OutBuf.init(out_ptr, out_len) orelse return err_invalid;
    const self = fromHandle(t) orelse return err_invalid;
    const buf = renderReplayAlloc(&self.terminal) catch return err_nomem;
    out.set(buf);
    return 0;
}

/// Builds the replay byte sequence. Read-only over the terminal:
/// repeated calls must produce identical bytes and leave state intact.
///
/// ghostty's own TerminalFormatter with `Extra.all` is close to what we
/// need but emits tabstops and scrolling-region sequences *after* the
/// final CUP, both of which move the cursor. We compose the same
/// building blocks manually so the active screen's CUP lands last.
fn renderReplayAlloc(term: *const vt.Terminal) ![]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    const w = &builder.writer;

    // Known-blank slate even on a non-blank target terminal: RIS
    // restores default modes/screens/tabstops, 3J drops scrollback
    // (RIS alone keeps it).
    try w.writeAll("\x1bc\x1b[3J");

    // Palette entries modified via OSC 4, and dynamic fg/bg/cursor
    // color overrides (OSC 10/11/12). Diff-based on purpose (upstream's
    // palette extra dumps all 256 entries unconditionally).
    {
        const palette = &term.colors.palette;
        var it = palette.mask.iterator(.{});
        while (it.next()) |idx| {
            const rgb = palette.current[idx];
            try w.print(
                "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                .{ idx, rgb.r, rgb.g, rgb.b },
            );
        }
    }
    if (term.colors.foreground.override) |rgb| try w.print(
        "\x1b]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
        .{ rgb.r, rgb.g, rgb.b },
    );
    if (term.colors.background.override) |rgb| try w.print(
        "\x1b]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
        .{ rgb.r, rgb.g, rgb.b },
    );
    if (term.colors.cursor.override) |rgb| try w.print(
        "\x1b]12;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
        .{ rgb.r, rgb.g, rgb.b },
    );

    // With the alternate screen engaged, rebuild the primary screen
    // first; the mode replay below then emits the matching alt-screen
    // mode set (?47/?1047/?1049), performing the switch on the target
    // before the alt content lands. The primary cursor is restored with
    // an absolute CUP: at this point in the byte stream the target
    // still has default modes, even if origin mode is set later.
    const alt_active = term.screens.active_key == .alternate;
    if (alt_active) {
        if (term.screens.get(.primary)) |primary| {
            try emitScreenContent(w, primary);
            try emitScreenExtras(w, primary);
            try emitCursorRestore(w, term, primary, false);
        }
    }

    // Terminal modes that differ from their defaults. Safe to emit
    // before content because content is emitted row-by-row and never
    // relies on autowrap.
    //
    // DECCOLM's gate must come first: the mode table declares mode 3
    // (132_column) before mode 40 (enable_mode_3), but a target that
    // sees ?3h before ?40h silently drops the column-mode switch.
    const allow_deccolm = term.modes.get(.enable_mode_3);
    if (allow_deccolm != @field(term.modes.default, "enable_mode_3")) {
        const suffix: []const u8 = if (allow_deccolm) "h" else "l";
        try w.print("\x1b[?40{s}", .{suffix});
    }
    // The mode bits record every mouse-tracking mode ever set, but the
    // active one on a real terminal is last-write-wins across a single
    // mutually exclusive field. Hold the winner back from the
    // table-ordered loop and emit it after, so it wins on the target
    // too regardless of mode-table order.
    const mouse_winner: ?vt.Mode = switch (term.flags.mouse_event) {
        .none => null,
        .x10 => .mouse_event_x10,
        .normal => .mouse_event_normal,
        .button => .mouse_event_button,
        .any => .mouse_event_any,
    };
    inline for (@typeInfo(vt.Mode).@"enum".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "enable_mode_3")) {
            const mode: vt.Mode = @enumFromInt(field.value);
            const current = term.modes.get(mode);
            const default_val = @field(term.modes.default, field.name);
            if (current != default_val and mode != mouse_winner) {
                const tag: vt.modes.ModeTag = @bitCast(@intFromEnum(mode));
                const prefix = if (tag.ansi) "" else "?";
                const suffix = if (current) "h" else "l";
                try w.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
            }
        }
    }
    if (mouse_winner) |winner| {
        const tag: vt.modes.ModeTag = @bitCast(@intFromEnum(winner));
        try w.print("\x1b[?{d}h", .{tag.value});
    }

    // Entering the alt screen copied the primary screen's pen and
    // charset state into it; neutralize both so the content below lands
    // verbatim. The alt extras at the end re-apply the real end state.
    if (alt_active) {
        // SGR reset, then GL := G0 (SI) and GR := G2 (LS2R).
        try w.writeAll("\x1b[0m\x0f\x1b}");

        // If the inherited G0 charset remaps ASCII, re-designate it to
        // ASCII for the content feed. The alt extras can always restore
        // the final G0: no sequence designates utf8, but an alt G0 of
        // utf8 implies the inherited (primary) G0 was already utf8, so
        // this branch won't have fired in that case.
        if (term.screens.get(.primary)) |primary| {
            switch (primary.charset.charsets.get(.G0)) {
                .utf8, .ascii => {},
                .british, .dec_special => try w.writeAll("\x1b(B"),
            }
        }
    }

    // An alt-screen switch copies the previous screen's cursor, so home
    // it before laying down the active screen's rows.
    try w.writeAll("\x1b[H");
    try emitScreenContent(w, term.screens.active);

    // Margins, tabstops, modifyOtherKeys, and OSC 7 come from ghostty's
    // own TerminalFormatter so their emission tracks upstream. They
    // must stay after content (margins would confine the row feed to
    // the scroll region) and before the final CUP (DECSTBM homes the
    // cursor and tabstop emission moves it), which is why the
    // ready-made `Extra.all` preset isn't usable.
    var tail: vt.formatter.TerminalFormatter = .init(term, .{ .emit = .vt });
    tail.content = .none;
    tail.extra = .none;
    tail.extra.scrolling_region = true;
    tail.extra.tabstops = true;
    tail.extra.keyboard = true;
    tail.extra.pwd = true;
    try tail.format(w);

    // Active screen extras, then the cursor restore last.
    try emitScreenExtras(w, term.screens.active);
    try emitCursorRestore(w, term, term.screens.active, true);

    return builder.toOwnedSlice();
}

/// Number of rows up to and including the last row containing text.
/// Scans bottom-up so a mostly-blank tail exits early.
fn contentRows(pages: *const vt.PageList, total: usize) usize {
    var blank_tail: usize = 0;
    var it = pages.rowIterator(.left_up, .{ .screen = .{} }, null);
    while (it.next()) |pin| {
        const rac = pin.rowAndCell();
        const cells = pin.node.data.getCells(rac.row);
        if (vt.Cell.hasTextAny(cells)) return total - blank_tail;
        blank_tail += 1;
    }
    return 0;
}

/// Emits one screen's cell contents (scrollback + visible area) as VT
/// bytes: rows top to bottom, each terminated by CR LF, with SGR
/// transitions where cell styles change.
fn emitScreenContent(w: *std.Io.Writer, screen: *const vt.Screen) !void {
    var content: vt.formatter.PageListFormatter = .init(&screen.pages, .{
        .emit = .vt,
        // Re-emit each visual row as-is instead of relying on the
        // target's autowrap: correct even when DECAWM is off, at the
        // cost of losing soft-wrap flags on the target (invisible to
        // plain dumps; noted for P2).
        .unwrap = false,
        // Trailing space cells are real cells; dropping them would
        // desync dumps that preserve them (dump_text uses trim=false).
        .trim = false,
    });
    try content.format(w);

    // The formatter emits `content_rows - 1` newlines (it never emits
    // trailing blank rows), but the blank tail still determines
    // scrollback depth and which line each visible row holds. Pad until
    // the target has seen `total - 1` newlines so its row count and row
    // alignment match ours. The `max(.., 1)` covers the no-content
    // case, where the formatter emitted zero newlines rather than -1.
    const total = screen.pages.total_rows;
    const content_rows = contentRows(&screen.pages, total);
    const padding = total - @max(content_rows, 1);
    for (0..padding) |_| try w.writeAll("\r\n");
}

/// Emits one screen's non-content state: SGR style, hyperlink,
/// protection, kitty keyboard flags, and charsets. The cursor is
/// excluded; use `emitCursorRestore` so it can land after any
/// cursor-moving emissions.
fn emitScreenExtras(w: *std.Io.Writer, screen: *const vt.Screen) !void {
    var extras: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt });
    extras.content = .none;
    extras.extra = .all;
    extras.extra.cursor = false;
    try extras.format(w);
}

/// Restores the cursor via CUP. With origin mode in effect, a target
/// terminal interprets CUP relative to the scrolling region (and `?6h`
/// itself homes the cursor, so toggling origin off/on around an
/// absolute CUP cannot work); emit region-relative coordinates then.
/// `origin_applies` is false while replaying the primary screen under
/// an engaged alt screen: at that point in the byte stream the target
/// hasn't received the mode replay yet, so CUP is always absolute.
fn emitCursorRestore(
    w: *std.Io.Writer,
    term: *const vt.Terminal,
    screen: *const vt.Screen,
    origin_applies: bool,
) !void {
    const cursor = &screen.cursor;
    var row: usize = @as(usize, cursor.y) + 1;
    var col: usize = @as(usize, cursor.x) + 1;
    if (origin_applies and term.modes.get(.origin)) {
        row = @as(usize, cursor.y -| term.scrolling_region.top) + 1;
        col = @as(usize, cursor.x -| term.scrolling_region.left) + 1;
    }
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

pub export fn gvt_buffer_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    alloc.free(p[0..len]);
}

/// Plain-text dump of scrollback + visible screen of the active screen,
/// used by tests to assert state equivalence. Buffer ownership passes to
/// the caller, who must release it via `gvt_buffer_free`.
pub export fn gvt_dump_text(
    t: ?*anyopaque,
    out_ptr: ?*?[*]u8,
    out_len: ?*usize,
) callconv(.c) i32 {
    const out = OutBuf.init(out_ptr, out_len) orelse return err_invalid;
    const self = fromHandle(t) orelse return err_invalid;
    const text = self.terminal.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    ) catch return err_nomem;
    out.set(@constCast(text));
    return 0;
}

pub export fn gvt_cursor_pos(
    t: ?*anyopaque,
    out_row: ?*u16,
    out_col: ?*u16,
) callconv(.c) i32 {
    if (out_row) |r| r.* = 0;
    if (out_col) |c| c.* = 0;
    const self = fromHandle(t) orelse return err_invalid;
    const cursor = &self.terminal.screens.active.cursor;
    if (out_row) |r| r.* = cursor.y;
    if (out_col) |c| c.* = cursor.x;
    return 0;
}

/// Total rows tracked (scrollback + visible) for the active screen.
/// Oracle for scrollback-depth regressions that `gvt_dump_text` alone
/// can miss (trailing blank rows, byte-budget eviction).
pub export fn gvt_total_rows(
    t: ?*anyopaque,
    out_total: ?*u32,
) callconv(.c) i32 {
    const ot = out_total orelse return err_invalid;
    ot.* = 0;
    const self = fromHandle(t) orelse return err_invalid;
    const total = self.terminal.screens.active.pages.total_rows;
    ot.* = std.math.cast(u32, total) orelse return err_invalid;
    return 0;
}

/// Responder callback contract for detached-mode queries (P2). Wired
/// here for ABI stability; not exercised by any P1 test. `bytes` is
/// non-nullable, matching the Rust-side declaration.
pub const gvt_responder_fn = *const fn (
    ctx: ?*anyopaque,
    bytes: [*]const u8,
    len: usize,
) callconv(.c) void;

pub export fn gvt_terminal_set_responder(
    t: ?*anyopaque,
    ctx: ?*anyopaque,
    responder: ?gvt_responder_fn,
) callconv(.c) void {
    const self = fromHandle(t) orelse return;
    self.responder_ctx = ctx;
    self.responder = responder;
}

test "feed and dump round-trip" {
    const handle = gvt_terminal_new(80, 24, 65536);
    try std.testing.expect(handle != null);
    defer gvt_terminal_free(handle);

    try std.testing.expectEqual(@as(i32, 0), gvt_terminal_feed(handle, "hi", 2));

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), gvt_dump_text(handle, &ptr, &len));
    defer gvt_buffer_free(ptr, len);
    try std.testing.expectEqualStrings("hi", ptr.?[0..len]);
}

test "replay of a blank terminal feeds cleanly into another" {
    const a = gvt_terminal_new(80, 24, 65536);
    try std.testing.expect(a != null);
    defer gvt_terminal_free(a);

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), gvt_render_replay(a, &ptr, &len));
    defer gvt_buffer_free(ptr, len);
    try std.testing.expect(len > 0);

    const b = gvt_terminal_new(80, 24, 65536);
    try std.testing.expect(b != null);
    defer gvt_terminal_free(b);
    try std.testing.expectEqual(@as(i32, 0), gvt_terminal_feed(b, ptr.?, len));
}

test "total rows of a fresh terminal equals its height" {
    const handle = gvt_terminal_new(80, 24, 65536);
    try std.testing.expect(handle != null);
    defer gvt_terminal_free(handle);

    var total: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), gvt_total_rows(handle, &total));
    try std.testing.expectEqual(@as(u32, 24), total);
}
