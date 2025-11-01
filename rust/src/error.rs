use thiserror::Error;
use std::path::PathBuf;

#[derive(Error, Debug)]
pub enum AppError {
    #[error("Configuration error: {0}")]
    Config(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Lock error: {0}")]
    Lock(String),

    #[error("Sync error: {0}")]
    Sync(String),

    #[error("Crypto error: {0}")]
    Crypto(String),

    #[error("Network error: {0}")]
    Network(String),

    #[error("Validation error: {0}")]
    Validation(String),

    #[error("Path traversal detected: {0}")]
    PathTraversal(PathBuf),

    #[error("Timeout exceeded for operation: {0}")]
    Timeout(String),

    #[error("pCloud not mounted: {0}")]
    PCloudNotMounted(String),

    #[error("Insufficient disk space: {0}")]
    InsufficientSpace(String),

    #[error("Process already running (PID: {0})")]
    AlreadyRunning(u32),
}

impl From<toml::de::Error> for AppError {
    fn from(err: toml::de::Error) -> Self {
        AppError::Config(format!("TOML parsing error: {}", err))
    }
}

impl From<toml::ser::Error> for AppError {
    fn from(err: toml::ser::Error) -> Self {
        AppError::Config(format!("TOML serialization error: {}", err))
    }
}

pub type Result<T> = std::result::Result<T, AppError>;