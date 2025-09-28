use std::fs::{OpenOptions, File};
use std::io::{Write, BufWriter};
use std::path::PathBuf;
use chrono::Local;
use anyhow::Result;
use crate::config::Config;

pub struct Logger {
    log_file: Option<BufWriter<File>>,
    config: Config,
    verbose: bool,
    debug: bool,
}

impl Logger {
    pub fn new(config: Config, verbose: bool, debug: bool) -> Result<Self> {
        let log_file = Self::initialize_log_file(&config)?;
        
        Ok(Logger {
            log_file,
            config,
            verbose,
            debug,
        })
    }
    
    fn initialize_log_file(config: &Config) -> Result<Option<BufWriter<File>>> {
        let log_path = PathBuf::from(&config.files.log_file);
        
        // Crear directorio padre si no existe
        if let Some(parent) = log_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        
        // Rotar log si es muy grande
        if log_path.exists() {
            let metadata = std::fs::metadata(&log_path)?;
            if metadata.len() > 10 * 1024 * 1024 { // 10MB
                let backup_path = log_path.with_extension("old");
                std::fs::rename(&log_path, backup_path)?;
            }
        }
        
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)?;
            
        Ok(Some(BufWriter::new(file)))
    }
    
    pub fn log(&mut self, level: &str, message: &str) {
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");
        let log_message = format!("{} - [{}] {}\n", timestamp, level, message);
        
        // Escribir en archivo
        if let Some(ref mut writer) = self.log_file {
            let _ = writer.write_all(log_message.as_bytes());
            let _ = writer.flush();
        }
        
        // Escribir en consola con colores
        self.console_log(level, message);
    }
    
    fn console_log(&self, level: &str, message: &str) {
        let (color, icon) = match level {
            "INFO" => (&self.config.colors.blue, &self.config.icons.info_icon),
            "WARN" => (&self.config.colors.yellow, &self.config.icons.warning_icon),
            "ERROR" => (&self.config.colors.red, &self.config.icons.cross_mark),
            "SUCCESS" => (&self.config.colors.green, &self.config.icons.check_mark),
            "DEBUG" => (&self.config.colors.magenta, &self.config.icons.clock_icon),
            _ => (&self.config.colors.white, ""),
        };
        
        if level == "DEBUG" && !self.debug && !self.verbose {
            return;
        }
        
        let formatted = format!("{}{} [{}] {}{}", 
            color, icon, level, message, self.config.colors.no_color);
        
        if level == "ERROR" {
            eprintln!("{}", formatted);
        } else {
            println!("{}", formatted);
        }
    }
    
    pub fn info(&mut self, message: &str) {
        self.log("INFO", message);
    }
    
    pub fn warn(&mut self, message: &str) {
        self.log("WARN", message);
    }
    
    pub fn error(&mut self, message: &str) {
        self.log("ERROR", message);
    }
    
    pub fn success(&mut self, message: &str) {
        self.log("SUCCESS", message);
    }
    
    pub fn debug(&mut self, message: &str) {
        self.log("DEBUG", message);
    }
}

// Macro para facilitar el logging
#[macro_export]
macro_rules! log_info {
    ($logger:expr, $($arg:tt)*) => {
        $logger.info(&format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_warn {
    ($logger:expr, $($arg:tt)*) => {
        $logger.warn(&format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_error {
    ($logger:expr, $($arg:tt)*) => {
        $logger.error(&format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_success {
    ($logger:expr, $($arg:tt)*) => {
        $logger.success(&format!($($arg)*));
    };
}

#[macro_export]
macro_rules! log_debug {
    ($logger:expr, $($arg:tt)*) => {
        $logger.debug(&format!($($arg)*));
    };
}