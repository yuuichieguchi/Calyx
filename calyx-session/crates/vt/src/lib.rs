//! Safe wrapper around `vt-sys` (`libgvt`): a VT terminal that can dump
//! its state as plain text and render a replay byte sequence sufficient
//! to reconstruct that state on a blank terminal of the same size.

mod error;

use std::os::raw::c_void;
use std::ptr;

pub use error::VtError;

/// A single ghostty-vt terminal instance, owned via an opaque libgvt
/// handle.
///
/// Deliberately neither `Send` nor `Sync`: whether the underlying Zig
/// `Terminal` tolerates being moved across threads has not been
/// verified against ghostty's internals. Revisit for the daemon (P2).
#[derive(Debug)]
pub struct Terminal {
    handle: *mut c_void,
}

impl Terminal {
    /// Creates a new terminal of the given size with the given
    /// scrollback capacity (in bytes).
    pub fn new(cols: u16, rows: u16, max_scrollback_bytes: u32) -> Result<Self, VtError> {
        let handle = unsafe { vt_sys::gvt_terminal_new(cols, rows, max_scrollback_bytes) };
        if handle.is_null() {
            return Err(VtError::TerminalCreationFailed);
        }
        Ok(Self { handle })
    }

    /// Feeds raw bytes (text and/or escape sequences) into the
    /// terminal's VT parser.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), VtError> {
        let rc = unsafe { vt_sys::gvt_terminal_feed(self.handle, bytes.as_ptr(), bytes.len()) };
        VtError::from_code(rc, "Terminal::feed")
    }

    /// Resizes the terminal in place.
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), VtError> {
        let rc = unsafe { vt_sys::gvt_terminal_resize(self.handle, cols, rows) };
        VtError::from_code(rc, "Terminal::resize")
    }

    /// Renders a byte sequence that reconstructs this terminal's current
    /// state (screen + scrollback + modes + cursor) when fed into a
    /// blank terminal of the same size. Non-destructive: may be called
    /// repeatedly without changing this terminal's state.
    pub fn render_replay(&mut self) -> Result<Vec<u8>, VtError> {
        let mut out_ptr: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe { vt_sys::gvt_render_replay(self.handle, &mut out_ptr, &mut out_len) };
        VtError::from_code(rc, "Terminal::render_replay")?;
        Ok(unsafe { take_buffer(out_ptr, out_len) })
    }

    /// Returns a plain-text dump of the screen plus scrollback, for
    /// state-equivalence assertions in tests.
    pub fn dump_text(&mut self) -> Result<String, VtError> {
        let mut out_ptr: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = unsafe { vt_sys::gvt_dump_text(self.handle, &mut out_ptr, &mut out_len) };
        VtError::from_code(rc, "Terminal::dump_text")?;
        let bytes = unsafe { take_buffer(out_ptr, out_len) };
        String::from_utf8(bytes).map_err(|_| VtError::InvalidUtf8("Terminal::dump_text"))
    }

    /// Returns the cursor position as 0-indexed `(row, col)`, matching
    /// ghostty's internal `Screen.Cursor.{x,y}` convention.
    pub fn cursor_pos(&mut self) -> Result<(u16, u16), VtError> {
        let mut row: u16 = 0;
        let mut col: u16 = 0;
        let rc = unsafe { vt_sys::gvt_cursor_pos(self.handle, &mut row, &mut col) };
        VtError::from_code(rc, "Terminal::cursor_pos")?;
        Ok((row, col))
    }

    /// Returns the total number of rows this terminal is tracking
    /// (scrollback plus visible area) for the active screen. An oracle
    /// for scrollback-depth bugs that don't show up in `dump_text` (e.g.
    /// trailing blank rows, or a byte budget that evicts more or fewer
    /// rows than intended).
    pub fn total_rows(&mut self) -> Result<u32, VtError> {
        let mut total: u32 = 0;
        let rc = unsafe { vt_sys::gvt_total_rows(self.handle, &mut total) };
        VtError::from_code(rc, "Terminal::total_rows")?;
        Ok(total)
    }
}

/// Copies a shim-owned buffer into a Rust-owned `Vec<u8>` and releases
/// the original via `gvt_buffer_free`.
///
/// # Safety
/// `ptr`/`len` must be either `(null, _)` or a valid libgvt buffer
/// previously returned by a `gvt_*` out-param pair not yet freed.
unsafe fn take_buffer(ptr: *mut u8, len: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    let owned = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    unsafe { vt_sys::gvt_buffer_free(ptr, len) };
    owned
}

impl Drop for Terminal {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { vt_sys::gvt_terminal_free(self.handle) };
        }
    }
}
