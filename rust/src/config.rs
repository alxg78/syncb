use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use anyhow::{Result, Context};
use dirs::home_dir;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub paths: Paths,
    pub crypto: Crypto,
    pub files: Files,
    pub general: General,
    pub directorios_sincronizacion: Vec<String>,
    pub exclusiones: Vec<String>,
    #[serde(rename = "host_specific")]
    pub host_specific: Option<HashMap<String, HostSpecific>>,
    pub permisos_ejecutables: Option<PermisosEjecutables>,
    pub logging: Option<Logging>,
    pub notifications: Option<Notifications>,
    pub colors: Colors,
    pub icons: Icons,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Paths {
    pub local_dir: String,
    pub pcloud_mount_point: String,
    pub pcloud_backup_comun: String,
    pub pcloud_backup_readonly: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Crypto {
    pub local_crypto_dir: String,
    pub remote_crypto_dir: String,
    pub cloud_mount_check_file: String,
    pub local_keepass_dir: String,
    pub remote_keepass_dir: String,
    pub local_crypto_hostname_rtva_dir: String,
    pub remote_crypto_hostname_rtva_dir: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Files {
    pub lista_por_defecto: String,
    pub lista_especifica_por_defecto: String,
    pub exclusiones_file: String,
    pub symlinks_file: String,
    pub log_file: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct General {
    pub lock_timeout: u64,
    pub hostname_rtva: String,
    pub default_timeout_minutes: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct HostSpecific {
    pub directorios_sincronizacion: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct PermisosEjecutables {
    pub archivos: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Logging {
    pub max_size_mb: u64,
    pub backup_count: u32,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Notifications {
    pub enabled: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Colors {
    pub red: String,
    pub green: String,
    pub yellow: String,
    pub blue: String,
    pub magenta: String,
    pub cyan: String,
    pub white: String,
    pub no_color: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Icons {
    pub check_mark: String,
    pub cross_mark: String,
    pub info_icon: String,
    pub warning_icon: String,
    pub clock_icon: String,
    pub sync_icon: String,
    pub error_icon: String,
    pub success_icon: String,
}

impl Config {
    pub fn load(config_path: &str) -> Result<Self> {
        let config_content = fs::read_to_string(config_path)
            .context("No se pudo leer el archivo de configuración")?;
        
        let mut config: Config = toml::from_str(&config_content)
            .context("Error parseando el archivo TOML")?;
        
        // Expandir paths con ~
        config.expand_paths()?;
        
        Ok(config)
    }
    
    fn expand_paths(&mut self) -> Result<()> {
        let home = home_dir().context("No se pudo determinar el directorio home")?;
        
        // Expandir paths en la sección paths
        self.paths.local_dir = expand_tilde(&self.paths.local_dir, &home);
        self.paths.pcloud_mount_point = expand_tilde(&self.paths.pcloud_mount_point, &home);
        self.paths.pcloud_backup_comun = expand_tilde(&self.paths.pcloud_backup_comun, &home);
        self.paths.pcloud_backup_readonly = expand_tilde(&self.paths.pcloud_backup_readonly, &home);
        
        // Expandir paths en la sección crypto
        self.crypto.local_crypto_dir = expand_tilde(&self.crypto.local_crypto_dir, &home);
        self.crypto.remote_crypto_dir = expand_tilde(&self.crypto.remote_crypto_dir, &home);
        self.crypto.local_keepass_dir = expand_tilde(&self.crypto.local_keepass_dir, &home);
        self.crypto.remote_keepass_dir = expand_tilde(&self.crypto.remote_keepass_dir, &home);
        self.crypto.local_crypto_hostname_rtva_dir = expand_tilde(&self.crypto.local_crypto_hostname_rtva_dir, &home);
        self.crypto.remote_crypto_hostname_rtva_dir = expand_tilde(&self.crypto.remote_crypto_hostname_rtva_dir, &home);
        
        // Expandir log file
        self.files.log_file = expand_tilde(&self.files.log_file, &home);
        
        Ok(())
    }
    
    pub fn get_hostname(&self) -> Result<String> {
        Ok(hostname::get()
            .context("No se pudo obtener el hostname")?
            .to_string_lossy()
            .to_string())
    }
    
    pub fn get_pcloud_dir(&self, backup_dir_mode: &BackupDirMode) -> PathBuf {
        match backup_dir_mode {
            BackupDirMode::ReadOnly => PathBuf::from(&self.paths.pcloud_backup_readonly),
            BackupDirMode::Comun => PathBuf::from(&self.paths.pcloud_backup_comun),
        }
    }
    
    pub fn get_sync_list(&self) -> Result<Vec<String>> {
        let hostname = self.get_hostname()?;
        
        // Si el hostname coincide con hostname_rtva, usar la configuración específica si existe
        if hostname == self.general.hostname_rtva {
            if let Some(host_specific) = &self.host_specific {
                if let Some(specific_config) = host_specific.get(&self.general.hostname_rtva) {
                    return Ok(specific_config.directorios_sincronizacion.clone());
                }
            }
        }
        
        // Usar la lista general
        Ok(self.directorios_sincronizacion.clone())
    }
    
    pub fn get_exclusions(&self) -> Vec<String> {
        self.exclusiones.clone()
    }
}

fn expand_tilde(path: &str, home: &Path) -> String {
    if path.starts_with("~/") {
        home.join(&path[2..]).to_string_lossy().to_string()
    } else {
        path.to_string()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum BackupDirMode {
    Comun,
    ReadOnly,
}

impl std::fmt::Display for BackupDirMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BackupDirMode::Comun => write!(f, "comun"),
            BackupDirMode::ReadOnly => write!(f, "readonly"),
        }
    }
}