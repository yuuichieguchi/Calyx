//! Safe wrapper around `vt-sys` (`libgvt`): a VT terminal that can dump
//! its state as plain text and render a replay byte sequence sufficient
//! to reconstruct that state on a blank terminal of the same size.

mod error;

use std::os::raw::c_void;
use std::ptr;

pub use error::VtError;

/// The boxed form a registered responder closure is stored in. Double
/// boxing turns the fat `dyn` pointer into a thin, stable heap address
/// usable as the C callback's `ctx`.
type ResponderClosure = Box<dyn FnMut(&[u8])>;

/// A single ghostty-vt terminal instance, owned via an opaque libgvt
/// handle.
///
/// Deliberately neither `Send` nor `Sync`: whether the underlying Zig
/// `Terminal` tolerates being moved across threads has not been
/// verified against ghostty's internals. Revisit for the daemon (P2).
pub struct Terminal {
    handle: *mut c_void,
    responder: Option<Box<ResponderClosure>>,
}

impl Terminal {
    /// Creates a new terminal of the given size with the given
    /// scrollback capacity (in bytes).
    pub fn new(cols: u16, rows: u16, max_scrollback_bytes: u32) -> Result<Self, VtError> {
        let handle = unsafe { vt_sys::gvt_terminal_new(cols, rows, max_scrollback_bytes) };
        if handle.is_null() {
            return Err(VtError::TerminalCreationFailed);
        }
        Ok(Self {
            handle,
            responder: None,
        })
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

    /// Registers `responder` to be invoked with the raw bytes of any
    /// query-class response (DSR 6 cursor-position report, DA1,
    /// DECRQM) this terminal would emit while `feed`ing input in
    /// detached mode, i.e. with no real PTY/application on the other
    /// end to answer such queries itself (P2 daemon use case).
    ///
    /// Wraps `vt_sys::gvt_terminal_set_responder`; see
    /// `calyx-session/shim/src/gvt.zig` for the C ABI contract. The
    /// closure is invoked synchronously from within `feed`, and a
    /// second `set_responder` call replaces the first.
    pub fn set_responder<F>(&mut self, responder: F)
    where
        F: FnMut(&[u8]) + 'static,
    {
        let mut boxed: Box<ResponderClosure> = Box::new(Box::new(responder));
        let ctx = (&mut *boxed) as *mut ResponderClosure as *mut c_void;
        unsafe { vt_sys::gvt_terminal_set_responder(self.handle, ctx, Some(responder_trampoline)) };
        // Replace only after the shim points at the new box: the old
        // box must stay alive for as long as the shim could still call
        // into it.
        self.responder = Some(boxed);
    }

    /// Unregisters a previously set responder; subsequent queries are
    /// silently ignored again.
    pub fn clear_responder(&mut self) {
        unsafe { vt_sys::gvt_terminal_set_responder(self.handle, ptr::null_mut(), None) };
        self.responder = None;
    }
}

/// C-side entry point for responder callbacks.
///
/// # Safety (contract with `set_responder`)
/// `ctx` is the address of a live `ResponderClosure` owned by the
/// `Terminal` whose feed triggered this call; the shim only invokes it
/// synchronously during `gvt_terminal_feed`, while that borrow is
/// unique.
extern "C" fn responder_trampoline(ctx: *mut c_void, bytes: *const u8, len: usize) {
    if ctx.is_null() {
        return;
    }
    let closure = unsafe { &mut *(ctx as *mut ResponderClosure) };
    let slice = if len == 0 || bytes.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    closure(slice);
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
        // `responder` (if any) drops after the handle is freed, so the
        // shim can no longer call into the closure it pointed at.
    }
}

// Manual impl because the responder closure has no `Debug`; `derive`
// would otherwise be preferred.
impl std::fmt::Debug for Terminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Terminal")
            .field("handle", &self.handle)
            .field("responder", &self.responder.is_some())
            .finish()
    }
}
