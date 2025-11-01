use crate::cli::{Cli, SyncMode, BackupDirMode};
use crate::config::AppConfig;
use crate::error::{AppError, Result};
use crate::stats::SyncStats;
use std::path::{Path, PathBuf};
use std::process::Command;
use tokio::time::{timeout, Duration};

pub struct SyncManager {
    config: AppConfig,
    args: Cli,
}

impl SyncManager {
    pub fn new(config: AppConfig, args: Cli) -> Self {
        Self { config, args }
    }

    pub async fn perform_sync(&self, stats: &mut SyncStats) -> Result<()> {
        log::info!("Iniciando proceso de sincronización en modo: {:?}", self.args.get_mode());

        // Verificar precondiciones
        self.verify_preconditions().await?;

        // Procesar elementos principales
        self.sync_main_items(stats).await?;

        // Sincronizar Crypto si está habilitado
        if self.args.crypto {
            self.sync_crypto(stats).await?;
        }

        // Manejar enlaces simbólicos
        self.handle_symbolic_links(stats).await?;

        log::info!("Sincronización completada");
        Ok(())
    }

    async fn verify_preconditions(&self) -> Result<()> {
        // Verificar pCloud montado
        self.verify_pcloud_mounted().await?;

        // Verificar conectividad
        self.verify_connectivity().await?;

        // Verificar espacio en disco
        self.verify_disk_space().await?;

        // Verificar elementos de configuración
        self.verify_config_items().await?;

        Ok(())
    }

    async fn verify_pcloud_mounted(&self) -> Result<()> {
        let mount_point = &self.config.general.pcloud_mount_point;
        
        if !mount_point.exists() {
            return Err(AppError::PCloudNotMounted(
                format!("El punto de montaje no existe: {:?}", mount_point)
            ));
        }

        // Verificar si está realmente montado
        if !self.is_directory_mounted(mount_point).await? {
            return Err(AppError::PCloudNotMounted(
                format!("pCloud no está montado en: {:?}", mount_point)
            ));
        }

        log::info!("Verificación de pCloud montado: OK");
        Ok(())
    }

    async fn is_directory_mounted(&self, path: &Path) -> Result<bool> {
        // Implementar verificación de montaje específica del SO
        #[cfg(target_os = "linux")]
        {
            let output = Command::new("findmnt")
                .arg(path)
                .output()
                .map_err(|e| AppError::Sync(format!("Error ejecutando findmnt: {}", e)))?;
            
            Ok(output.status.success())
        }
        
        #[cfg(target_os = "macos")]
        {
            let output = Command::new("mount")
                .output()
                .map_err(|e| AppError::Sync(format!("Error ejecutando mount: {}", e)))?;
            
            let output_str = String::from_utf8_lossy(&output.stdout);
            Ok(output_str.contains(path.to_string_lossy().as_ref()))
        }
        
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        {
            // Fallback: verificar si el directorio está vacío
            match std::fs::read_dir(path) {
                Ok(mut entries) => Ok(entries.next().is_some()),
                Err(_) => Ok(false),
            }
        }
    }

    async fn verify_connectivity(&self) -> Result<()> {
        // Verificar conectividad a pCloud
        let status = Command::new("curl")
            .args(["-s", "--max-time", "5", "https://www.pcloud.com/"])
            .status();
            
        match status {
            Ok(exit_status) if exit_status.success() => {
                log::info!("Verificación de conectividad pCloud: OK");
                Ok(())
            }
            _ => {
                log::warn!("No se pudo verificar la conectividad con pCloud");
                Ok(()) // No fatal, solo advertencia
            }
        }
    }

    async fn verify_disk_space(&self) -> Result<()> {
        let required_space_mb = 500; // 500 MB mínimo
        
        let path = match self.args.get_mode() {
            SyncMode::Upload => &self.config.general.pcloud_mount_point,
            SyncMode::Download => &self.config.general.local_dir,
        };
        
        let available_space = self.get_available_space(path).await?;
        
        if available_space < required_space_mb {
            return Err(AppError::InsufficientSpace(
                format!("Espacio insuficiente en {:?}. Disponible: {}MB, Necesario: {}MB", 
                       path, available_space, required_space_mb)
            ));
        }
        
        log::info!("Verificación de espacio en disco: OK ({}MB disponibles)", available_space);
        Ok(())
    }

    async fn get_available_space(&self, path: &Path) -> Result<u64> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            
            let metadata = std::fs::metadata(path)?;
            let available = metadata.available_space() / (1024 * 1024); // Convertir a MB
            Ok(available)
        }
        
        #[cfg(not(unix))]
        {
            // Implementación para otros sistemas
            Ok(1000) // Valor por defecto para desarrollo
        }
    }

    async fn verify_config_items(&self) -> Result<()> {
        let host_config = self.config.get_current_host_config()?;
        
        for item in &host_config.sync_items {
            let full_path = self.config.general.local_dir.join(item);
            if !full_path.exists() {
                log::warn!("El elemento de configuración no existe: {:?}", full_path);
            }
        }
        
        Ok(())
    }

    async fn sync_main_items(&self, stats: &mut SyncStats) -> Result<()> {
        let host_config = self.config.get_current_host_config()?;
        let items_to_sync = if let Some(cli_items) = &self.args.items {
            cli_items
        } else {
            &host_config.sync_items
        };

        for item in items_to_sync {
            if let Err(e) = self.sync_item(item, stats).await {
                log::error!("Error sincronizando {}: {}", item, e);
                stats.record_error();
            } else {
                stats.record_successful_item();
            }
        }

        Ok(())
    }

    async fn sync_item(&self, item: &str, stats: &mut SyncStats) -> Result<()> {
        log::info!("Sincronizando: {}", item);
        
        let (source, destination) = self.get_sync_paths(item)?;
        
        // Construir comando rsync
        let mut command = self.build_rsync_command(&source, &destination)?;
        
        // Ejecutar con timeout
        let timeout_duration = Duration::from_secs(
            self.args.timeout.unwrap_or(self.config.general.default_timeout_minutes) as u64 * 60
        );
        
        match timeout(timeout_duration, self.execute_rsync(&mut command)).await {
            Ok(Ok(output)) => {
                self.process_rsync_output(&output, stats);
                Ok(())
            }
            Ok(Err(e)) => Err(e),
            Err(_) => Err(AppError::Timeout(format!("Operación excedió el tiempo límite para: {}", item))),
        }
    }

    fn get_sync_paths(&self, item: &str) -> Result<(PathBuf, PathBuf)> {
        let pcloud_dir = self.get_pcloud_dir();
        
        match self.args.get_mode() {
            SyncMode::Upload => {
                let source = self.config.general.local_dir.join(item);
                let destination = pcloud_dir.join(item);
                Ok((source, destination))
            }
            SyncMode::Download => {
                let source = pcloud_dir.join(item);
                let destination = self.config.general.local_dir.join(item);
                Ok((source, destination))
            }
        }
    }

    fn get_pcloud_dir(&self) -> PathBuf {
        match self.args.get_backup_dir_mode() {
            BackupDirMode::Common => self.config.general.pcloud_backup_comun.clone(),
            BackupDirMode::ReadOnly => self.config.general.pcloud_backup_readonly.clone(),
        }
    }

    fn build_rsync_command(&self, source: &Path, destination: &Path) -> Result<Command> {
        let mut command = Command::new("rsync");
        
        // Opciones base
        command.args(["-av", "--progress", "--itemize-changes"]);
        
        // Opciones condicionales
        if self.args.dry_run {
            command.arg("--dry-run");
        }
        
        if self.args.delete {
            command.arg("--delete-delay");
        }
        
        if !self.args.overwrite {
            command.arg("--update");
        }
        
        if self.args.checksum {
            command.arg("--checksum");
        }
        
        if let Some(bwlimit) = self.args.bwlimit {
            command.args(["--bwlimit", &bwlimit.to_string()]);
        }
        
        // Exclusiones
        let host_config = self.config.get_current_host_config()?;
        for exclusion in &host_config.exclusions {
            command.args(["--exclude", exclusion]);
        }
        
        for exclusion in &self.args.exclude {
            command.args(["--exclude", exclusion]);
        }
        
        // Rutas
        command.arg(source);
        command.arg(destination);
        
        Ok(command)
    }

    async fn execute_rsync(&self, command: &mut Command) -> Result<std::process::Output> {
        let output = command.output().map_err(|e| {
            AppError::Sync(format!("Error ejecutando rsync: {}", e))
        })?;
        
        Ok(output)
    }

    fn process_rsync_output(&self, output: &std::process::Output, stats: &mut SyncStats) {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let files_transferred = stdout.matches(">f").count();
            stats.record_files_transferred(files_transferred);
            log::info!("Sincronización completada: {} archivos transferidos", files_transferred);
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            log::error!("Error en rsync: {}", stderr);
        }
    }

    async fn sync_crypto(&self, stats: &mut SyncStats) -> Result<()> {
        log::info!("Sincronizando directorio Crypto");
        // Implementación específica para Crypto
        // Similar a sync_main_items pero con rutas específicas de Crypto
        Ok(())
    }

    async fn handle_symbolic_links(&self, stats: &mut SyncStats) -> Result<()> {
        match self.args.get_mode() {
            SyncMode::Upload => self.backup_symbolic_links(stats).await,
            SyncMode::Download => self.restore_symbolic_links(stats).await,
        }
    }

    async fn backup_symbolic_links(&self, _stats: &mut SyncStats) -> Result<()> {
        // Implementar backup de enlaces simbólicos
        log::info("Realizando backup de enlaces simbólicos");
        Ok(())
    }

    async fn restore_symbolic_links(&self, _stats: &mut SyncStats) -> Result<()> {
        // Implementar restauración de enlaces simbólicos
        log::info("Restaurando enlaces simbólicos");
        Ok(())
    }
}

// Funciones públicas para uso desde main
pub fn show_banner(args: &Cli, config: &AppConfig) {
    println!("==========================================");
    println!("Sincronización Bidireccional - syncb");
    println!("Modo: {:?}", args.get_mode());
    println!("Host: {}", config.get_hostname());
    println!("==========================================");
}

pub fn verify_dependencies() -> Result<()> {
    // Verificar que rsync está disponible
    let status = Command::new("rsync")
        .arg("--version")
        .status()
        .map_err(|e| AppError::Sync(format!("rsync no está disponible: {}", e)))?;
        
    if !status.success() {
        return Err(AppError::Sync("rsync no está funcionando correctamente".to_string()));
    }
    
    log::info!("Dependencias verificadas: OK");
    Ok(())
}

pub async fn verify_preconditions(config: &AppConfig) -> Result<()> {
    let temp_manager = SyncManager::new(config.clone(), Cli::default());
    temp_manager.verify_preconditions().await
}

pub fn confirm_execution() -> Result<()> {
    println!("¿Desea continuar con la sincronización? [s/N]: ");
    
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    
    if input.trim().eq_ignore_ascii_case("s") {
        Ok(())
    } else {
        Err(AppError::Validation("Operación cancelada por el usuario".to_string()))
    }
}

pub async fn perform_sync(args: &Cli, config: &AppConfig, stats: &mut SyncStats) -> Result<()> {
    let manager = SyncManager::new(config.clone(), args.clone());
    manager.perform_sync(stats).await
}