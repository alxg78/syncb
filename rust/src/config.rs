use crate::cli::Cli;
use crate::error::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

// DEFINICIÓN DE HOSTCONFIG - debe estar PRIMERO y en ESTE archivo
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostConfig {
    pub sync_items: Vec<String>,
    pub exclusions: Vec<String>,
}

// LUEGO los otros structs
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
pub struct AppConfig {
    pub general: GeneralConfig,
    pub hosts: HashMap<String, HostConfig>, // Ahora HostConfig está definido
    #[serde(default)]
    pub exclusion_patterns: Vec<String>,
}

impl AppConfig {
    pub fn load(args: &Cli) -> Result<Self> {
        let config_path = Self::find_config_file()?;
        let config_content = std::fs::read_to_string(&config_path)?;

        let mut config: AppConfig = toml::from_str(&config_content)?;

        // Aplicar expansión de ~ en las rutas
        config.expand_paths()?;

        // Apply command line overrides
        config.apply_cli_overrides(args);

        // Validate configuration
        config.validate()?;

        Ok(config)
    }

    fn find_config_file() -> Result<PathBuf> {
        let possible_paths = [
            PathBuf::from("syncb_config.toml"),
            PathBuf::from("./config.toml"),
            dirs::config_dir()
                .unwrap_or_default()
                .join("syncb/config.toml"),
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
        self.hosts
            .get(&hostname)
            .or_else(|| self.hosts.get("default"))
            .ok_or_else(|| {
                AppError::Config(format!("No configuration found for host '{}'", hostname))
            })
    }

    fn get_current_host_config_mut(&mut self) -> Option<&mut HostConfig> {
        let hostname = Self::get_hostname();

        // Solución al problema de double borrow
        if self.hosts.contains_key(&hostname) {
            self.hosts.get_mut(&hostname)
        } else {
            self.hosts.get_mut("default")
        }
    }

    pub fn get_hostname() -> String {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    }

    fn expand_paths(&mut self) -> Result<()> {
        // CORREGIDO: usar if let Some en lugar de if let Ok
        let expand_path = |path: &mut PathBuf| {
            if let Some(path_str) = path.to_str() {
                // to_str() devuelve Option<&str>, no Result
                if path_str.starts_with('~') {
                    if let Some(home_dir) = dirs::home_dir() {
                        let expanded = path_str.replacen('~', &home_dir.to_string_lossy(), 1);
                        *path = PathBuf::from(expanded);
                    }
                }
            }
        };

        expand_path(&mut self.general.local_dir);
        expand_path(&mut self.general.pcloud_mount_point);
        expand_path(&mut self.general.pcloud_backup_comun);
        expand_path(&mut self.general.pcloud_backup_readonly);
        expand_path(&mut self.general.log_file);
        expand_path(&mut self.general.lock_file);
        expand_path(&mut self.general.crypto.local_crypto_dir);
        expand_path(&mut self.general.crypto.remote_crypto_dir);
        expand_path(&mut self.general.crypto.local_keepass_dir);
        expand_path(&mut self.general.crypto.remote_keepass_dir);
        expand_path(&mut self.general.crypto.local_crypto_hostname_rtva_dir);
        expand_path(&mut self.general.crypto.remote_crypto_hostname_rtva_dir);

        Ok(())
    }

    fn validate(&self) -> Result<()> {
        // Validar que las rutas existen
        let paths_to_check = [&self.general.local_dir, &self.general.pcloud_mount_point];

        for path in &paths_to_check {
            if !path.exists() {
                log::warn!("El directorio no existe: {:?}", path);
            }
        }

        Ok(())
    }

    pub fn is_host_rtva(&self) -> bool {
        Self::get_hostname() == "feynman.rtva.dnf"
    }
}
