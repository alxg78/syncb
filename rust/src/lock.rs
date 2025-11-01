use crate::config::AppConfig;
use crate::error::{AppError, Result};
use nix::unistd::Pid;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct LockGuard {
    lock_file: std::path::PathBuf, // CAMBIADO a PathBuf
}

impl LockGuard {
    pub fn acquire(config: &AppConfig) -> Result<Self> {
        let lock_file = config.general.lock_file.clone(); // YA ES PathBuf

        // Verificar si el lock existe y es válido
        if let Some(pid) = Self::check_existing_lock(&lock_file)? {
            return Err(AppError::AlreadyRunning(pid));
        }

        // Crear nuevo lock
        Self::create_lock(&lock_file)?;

        Ok(Self { lock_file })
    }

    fn check_existing_lock(lock_file: &Path) -> Result<Option<u32>> {
        // CAMBIADO a &Path
        if !lock_file.exists() {
            // AHORA FUNCIONA
            return Ok(None);
        }

        let mut file = File::open(lock_file)?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;

        if let Some(pid_str) = contents.lines().next() {
            if let Ok(pid) = pid_str.parse::<u32>() {
                // Verificar si el proceso todavía está ejecutándose
                if Self::is_process_running(pid) {
                    return Ok(Some(pid));
                }
            }
        }

        // Lock obsoleto, eliminarlo
        std::fs::remove_file(lock_file)?;
        Ok(None)
    }

    fn is_process_running(pid: u32) -> bool {
        // Usar Pid::from_raw con el tipo correcto de nix
        match nix::sys::signal::kill(Pid::from_raw(pid as i32), None) {
            Ok(_) => true,
            Err(nix::errno::Errno::ESRCH) => false,
            Err(_) => true, // Otro error, asumir que está corriendo
        }
    }

    fn create_lock(lock_file: &Path) -> Result<()> {
        // CAMBIADO a &Path
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(lock_file)?;

        let pid = std::process::id();
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        writeln!(file, "{}", pid)?;
        writeln!(file, "timestamp: {}", timestamp)?;
        writeln!(
            file,
            "hostname: {}",
            hostname::get().unwrap().to_string_lossy()
        )?;

        Ok(())
    }
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock_file);
    }
}

pub fn force_unlock(config: &AppConfig) -> Result<()> {
    let lock_file = &config.general.lock_file;

    if lock_file.exists() {
        // AHORA FUNCIONA
        std::fs::remove_file(lock_file)?;
        log::info!("Lock forzado eliminado: {:?}", lock_file);
    }

    Ok(())
}
