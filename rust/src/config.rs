use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use crate::cli::Cli;
use crate::error::{AppError, Result};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub general: GeneralConfig,
    pub hosts: HashMap<String, HostConfig>,
    pub exclusion_patterns: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralConfig {
    pub local_dir: PathBuf,
    pub pcloud_mount_point: PathBuf,
    pub pcloud_backup_comun: PathBuf,
    pub pcloud_backup_readonly: PathBuf,
    pub log_file: PathBuf,
    pub lock_file: PathBuf,
    pub lock_timeout_seconds: u64,
    pub default_timeout_minutes: u32,
    pub crypto: CryptoConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CryptoConfig {
    pub local_crypto_dir: PathBuf,
    pub remote_crypto_dir: PathBuf,
    pub cloud_mount_check_file: String,
    pub local_keepass_dir: PathBuf,
    pub remote_keepass_dir: PathBuf,
    pub local_crypto_hostname_rtva_dir: PathBuf,
    pub remote_crypto_hostname_rtva_dir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostConfig {
    pub sync_items: Vec<String>,
    pub exclusions: Vec<String>,
}

impl AppConfig {
    pub fn load(args: &Cli) -> Result<Self> {
        let config_path = Self::find_config_file()?;
        let config_content = std::fs::read_to_string(&config_path)?;
        
        let mut config: AppConfig = toml::from_str(&config_content)?;
        
        // Apply command line overrides
        config.apply_cli_overrides(args);
        
        // Validate configuration
        config.validate()?;
        
        Ok(config)
    }
    
    fn find_config_file() -> Result<PathBuf> {
        let possible_paths = [
            PathBuf::from("syncb_config.toml"),
            dirs::config_dir().unwrap_or_default().join("syncb/config.toml"),
            PathBuf::from("/etc/syncb/config.toml"),
        ];
        
        for path in &possible_paths {
            if path.exists() {
                return Ok(path.clone());
            }
        }
        
        Err(AppError::Config("No configuration file found".to_string()))
    }
    
    fn apply_cli_overrides(&mut self, args: &Cli) {
        if let Some(items) = &args.items {
            if let Some(host_config) = self.get_current_host_config_mut() {
                host_config.sync_items = items.clone();
            }
        }
        
        if !args.exclude.is_empty() {
            if let Some(host_config) = self.get_current_host_config_mut() {
                host_config.exclusions.extend(args.exclude.clone());
            }
        }
    }
    
    pub fn get_current_host_config(&self) -> Result<&HostConfig> {
        let hostname = Self::get_hostname();
        self.hosts.get(&hostname)
            .or_else(|| self.hosts.get("default"))
            .ok_or_else(|| AppError::Config(format!("No configuration found for host '{}'", hostname)))
    }
    
    fn get_current_host_config_mut(&mut self) -> Option<&mut HostConfig> {
        let hostname = Self::get_hostname();
        self.hosts.get_mut(&hostname)
            .or_else(|| self.hosts.get_mut("default"))
    }
    
    fn get_hostname() -> String {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    }
    
    fn validate(&self) -> Result<()> {
        // Validate paths
        if !self.general.local_dir.exists() {
            return Err(AppError::Config(format!("Local directory does not exist: {:?}", self.general.local_dir)));
        }
        
        // Validate that paths are absolute and don't contain traversal
        self.validate_path(&self.general.local_dir)?;
        self.validate_path(&self.general.pcloud_mount_point)?;
        
        Ok(())
    }
    
    fn validate_path(&self, path: &Path) -> Result<()> {
        if !path.is_absolute() {
            return Err(AppError::Config(format!("Path must be absolute: {:?}", path)));
        }
        
        // Check for path traversal attempts
        let path_str = path.to_string_lossy();
        if path_str.contains("..") {
            return Err(AppError::PathTraversal(path.to_path_buf()));
        }
        
        Ok(())
    }
    
    pub fn is_host_rtva(&self) -> bool {
        Self::get_hostname() == "feynman.rtva.dnf"
    }
}