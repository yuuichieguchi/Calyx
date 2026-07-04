//! Raw (unsafe) FFI bindings to `libgvt`.
//!
//! See `calyx-session/shim/src/gvt.zig` for the authoritative C ABI
//! contract.

use std::os::raw::c_void;

/// Responder callback contract for detached-mode queries (P2). Declared
/// here for ABI stability; unused by any P1 code path.
pub type GvtResponderFn = extern "C" fn(ctx: *mut c_void, bytes: *const u8, len: usize);

unsafe extern "C" {
    /// Returns NULL on failure (including "not implemented" in P1).
    /// `max_scrollback_bytes` is a byte budget, not a line count.
    pub fn gvt_terminal_new(cols: u16, rows: u16, max_scrollback_bytes: u32) -> *mut c_void;

    pub fn gvt_terminal_free(t: *mut c_void);

    /// Returns 0 on success.
    pub fn gvt_terminal_feed(t: *mut c_void, bytes: *const u8, len: usize) -> i32;

    /// Returns 0 on success.
    pub fn gvt_terminal_resize(t: *mut c_void, cols: u16, rows: u16) -> i32;

    /// Returns 0 on success. On success, `*out_ptr`/`*out_len` describe a
    /// shim-owned buffer that must be released via `gvt_buffer_free`.
    pub fn gvt_render_replay(t: *mut c_void, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32;

    pub fn gvt_buffer_free(ptr: *mut u8, len: usize);

    /// Returns 0 on success. On success, `*out_ptr`/`*out_len` describe a
    /// shim-owned buffer that must be released via `gvt_buffer_free`.
    pub fn gvt_dump_text(t: *mut c_void, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32;

    /// Returns 0 on success.
    pub fn gvt_cursor_pos(t: *mut c_void, out_row: *mut u16, out_col: *mut u16) -> i32;

    /// Returns 0 on success. Total rows tracked (scrollback + visible)
    /// for the active screen.
    pub fn gvt_total_rows(t: *mut c_void, out_total: *mut u32) -> i32;

    pub fn gvt_terminal_set_responder(
        t: *mut c_void,
        ctx: *mut c_void,
        responder: Option<GvtResponderFn>,
    );
}
