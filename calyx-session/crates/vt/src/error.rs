//! Error type returned by the `vt` crate's safe wrapper.

use std::fmt;

/// Status code libgvt returns when the VT stream rejects fed bytes for
/// a reason other than allocation failure. Kept in sync with
/// `err_stream` in `calyx-session/shim/src/gvt.zig`.
const STREAM_ERROR_CODE: i32 = -71;

/// Errors surfaced by the `vt` crate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VtError {
    /// libgvt reports that the terminal handle could not be created
    /// (`gvt_terminal_new` returned NULL): invalid dimensions or
    /// allocation failure.
    TerminalCreationFailed,
    /// libgvt's VT stream failed to process the bytes fed to it.
    Stream(&'static str),
    /// libgvt returned an unrecognized non-zero status code.
    Code { op: &'static str, code: i32 },
    /// A dump/replay buffer libgvt handed back was not valid UTF-8.
    InvalidUtf8(&'static str),
}

impl VtError {
    /// Converts a libgvt status code into a `Result<(), VtError>` for
    /// the given operation name (used in error messages/variants).
    pub(crate) fn from_code(code: i32, op: &'static str) -> Result<(), VtError> {
        match code {
            0 => Ok(()),
            STREAM_ERROR_CODE => Err(VtError::Stream(op)),
            other => Err(VtError::Code { op, code: other }),
        }
    }
}

impl fmt::Display for VtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VtError::TerminalCreationFailed => write!(f, "Terminal::new: libgvt returned NULL"),
            VtError::Stream(op) => write!(f, "{op}: libgvt VT stream failed to process input"),
            VtError::Code { op, code } => write!(f, "{op}: libgvt returned code {code}"),
            VtError::InvalidUtf8(op) => write!(f, "{op}: invalid utf-8 in libgvt output"),
        }
    }
}

impl std::error::Error for VtError {}
