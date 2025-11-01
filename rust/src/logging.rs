use crate::config::AppConfig;
use crate::error::Result;
use chrono::Local;
use log::{LevelFilter, Record};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

pub struct Logger {
    log_file: PathBuf,
}

impl Logger {
    pub fn init(config: &AppConfig) -> Result<Self> {
        let log_file = config.general.log_file.clone();

        // Configurar env_logger
        env_logger::Builder::new()
            .filter_level(if config.is_host_rtva() {
                LevelFilter::Debug
            } else {
                LevelFilter::Info
            })
            .format(Self::log_format)
            .init();

        // Crear archivo de log
        if let Some(parent) = log_file.parent() {
            std::fs::create_dir_all(parent)?;
        }

        File::create(&log_file)?;

        Ok(Self { log_file })
    }

    fn log_format(buf: &mut env_logger::fmt::Formatter, record: &Record) -> std::io::Result<()> {
        let level = record.level();
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");

        // Colores para niveles (solo en terminal)
        let colored_level = match level {
            log::Level::Error => format!("\x1b[31m{}\x1b[0m", level), // Rojo
            log::Level::Warn => format!("\x1b[33m{}\x1b[0m", level),  // Amarillo
            log::Level::Info => format!("\x1b[34m{}\x1b[0m", level),  // Azul
            log::Level::Debug => format!("\x1b[35m{}\x1b[0m", level), // Magenta
            log::Level::Trace => format!("\x1b[36m{}\x1b[0m", level), // Cian
        };

        writeln!(buf, "{} [{}] {}", timestamp, colored_level, record.args())
    }

    pub fn log_to_file(&self, message: &str) -> Result<()> {
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");
        let log_entry = format!("{} - {}\n", timestamp, message);

        let mut file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.log_file)?;

        file.write_all(log_entry.as_bytes())?;

        // Rotación de logs si es necesario
        self.rotate_log_if_needed()?;

        Ok(())
    }

    fn rotate_log_if_needed(&self) -> Result<()> {
        if let Ok(metadata) = std::fs::metadata(&self.log_file) {
            if metadata.len() > 10 * 1024 * 1024 {
                // 10MB
                let rotated_name = format!("{}.old", self.log_file.display());
                std::fs::rename(&self.log_file, rotated_name)?;
            }
        }

        Ok(())
    }
}
