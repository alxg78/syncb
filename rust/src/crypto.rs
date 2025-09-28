use std::path::{Path, PathBuf};
use std::process::Command;
use anyhow::Result;
use crate::logging::Logger;
use crate::config::Config;

pub struct CryptoSync {
    config: Config,
    local_dir: PathBuf,
}

impl CryptoSync {
    pub fn new(config: Config, local_dir: PathBuf) -> Self {
        Self { config, local_dir }
    }
    
    pub fn verificar_montaje_crypto(&self, logger: &mut Logger) -> Result<bool> {
        let check_file = PathBuf::from(&self.config.crypto.remote_crypto_dir)
            .join(&self.config.crypto.cloud_mount_check_file);
            
        if check_file.exists() {
            log_debug!(logger, "Verificación de montaje Crypto: OK");
            Ok(true)
        } else {
            log_error!(logger, "El volumen Crypto no está montado o el archivo de verificación no existe");
            log_error!(logger, "Por favor, desbloquea/monta la unidad en: {}", 
                self.config.crypto.remote_crypto_dir);
            Ok(false)
        }
    }
    
    pub fn sincronizar_keepass(&self, dry_run: bool, logger: &mut Logger) -> Result<()> {
        let remote_keepass = PathBuf::from(&self.config.crypto.remote_keepass_dir);
        let local_keepass = PathBuf::from(&self.config.crypto.local_keepass_dir);
        
        if !remote_keepass.exists() {
            log_warn!(logger, "Directorio remoto de KeePass no existe: {}", remote_keepass.display());
            return Ok(());
        }
        
        // Crear directorio local si no existe
        if !local_keepass.exists() && !dry_run {
            fs::create_dir_all(&local_keepass)?;
        }
        
        let mut cmd = Command::new("rsync");
        cmd.arg("-av")
           .arg("--progress");
           
        if dry_run {
            cmd.arg("--dry-run");
        }
        
        cmd.arg(format!("{}/", remote_keepass.display()))
           .arg(format!("{}/", local_keepass.display()));
           
        log_info!(logger, "Sincronizando KeePass2Android...");
        log_debug!(logger, "Comando: {:?}", cmd);
        
        let output = cmd.output()?;
        
        if output.status.success() {
            log_success!(logger, "KeePass sincronizado correctamente");
        } else {
            log_error!(logger, "Error sincronizando KeePass: {}", String::from_utf8_lossy(&output.stderr));
        }
        
        Ok(())
    }
    
    pub fn sincronizar_crypto(
        &self, 
        modo: &crate::args::SyncMode,
        dry_run: bool,
        delete: bool,
        overwrite: bool,
        logger: &mut Logger
    ) -> Result<()> {
        let (origen, destino, direccion) = match modo {
            crate::args::SyncMode::Subir => {
                let origen = if self.config.get_hostname()? == self.config.general.hostname_rtva {
                    PathBuf::from(&self.config.crypto.local_crypto_hostname_rtva_dir)
                } else {
                    PathBuf::from(&self.config.crypto.local_crypto_dir)
                };
                let destino = PathBuf::from(&self.config.crypto.remote_crypto_dir);
                (origen, destino, "LOCAL → PCLOUD (Crypto Subir)")
            }
            crate::args::SyncMode::Bajar => {
                let origen = PathBuf::from(&self.config.crypto.remote_crypto_dir);
                let destino = if self.config.get_hostname()? == self.config.general.hostname_rtva {
                    PathBuf::from(&self.config.crypto.local_crypto_hostname_rtva_dir)
                } else {
                    PathBuf::from(&self.config.crypto.local_crypto_dir)
                };
                (origen, destino, "PCLOUD → LOCAL (Crypto Bajar)")
            }
        };
        
        if !origen.exists() {
            log_warn!(logger, "El origen no existe: {}", origen.display());
            if !dry_run {
                fs::create_dir_all(&origen)?;
                log_info!(logger, "Directorio creado: {}", origen.display());
            }
        }
        
        log_info!(logger, "Sincronizando Crypto: {} -> {} ({})", 
            origen.display(), destino.display(), direccion);
        
        let mut cmd = Command::new("rsync");
        cmd.arg("-av")
           .arg("--progress")
           .arg("--times")
           .arg("--whole-file")
           .arg("--itemize-changes")
           .arg("--exclude").arg(&self.config.crypto.cloud_mount_check_file);
           
        if !overwrite {
            cmd.arg("--update");
        }
        
        if dry_run {
            cmd.arg("--dry-run");
        }
        
        if delete {
            cmd.arg("--delete-delay");
        }
        
        // Añadir trailing slash para sincronizar contenido del directorio
        let origen_str = format!("{}/", origen.display());
        let destino_str = format!("{}/", destino.display());
        
        cmd.arg(&origen_str).arg(&destino_str);
        
        log_debug!(logger, "Comando Crypto: {:?}", cmd);
        
        let output = cmd.output()?;
        
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let archivos_transferidos = stdout.lines()
                .filter(|line| line.starts_with('>') && line.contains("f+++") || line.contains("f.st"))
                .count();
                
            log_success!(logger, "Sincronización Crypto completada: {} archivos transferidos", 
                archivos_transferidos);
        } else {
            log_error!(logger, "Error en sincronización Crypto: {}", 
                String::from_utf8_lossy(&output.stderr));
            return Err(anyhow::anyhow!("Error en sincronización Crypto"));
        }
        
        Ok(())
    }
}