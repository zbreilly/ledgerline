/// One error type crosses the FFI boundary. Swift sees it as `LedgerError.Message(msg:)`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LedgerError {
    #[error("{msg}")]
    Message { msg: String },
}

pub type Result<T> = std::result::Result<T, LedgerError>;

pub fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(LedgerError::Message { msg: msg.into() })
}

impl From<rusqlite::Error> for LedgerError {
    fn from(e: rusqlite::Error) -> Self {
        LedgerError::Message { msg: format!("Database error: {e}") }
    }
}

impl From<serde_json::Error> for LedgerError {
    fn from(e: serde_json::Error) -> Self {
        LedgerError::Message { msg: format!("JSON error: {e}") }
    }
}

impl From<std::io::Error> for LedgerError {
    fn from(e: std::io::Error) -> Self {
        LedgerError::Message { msg: format!("I/O error: {e}") }
    }
}
