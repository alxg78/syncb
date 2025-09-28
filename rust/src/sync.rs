use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};
use anyhow::{Result, Context};
use crate::logging::Logger;
use crate::args::{SyncMode, SyncArgs};
use crate::config::Config;

pub struct SyncStats {
    pub elementos_procesados: u32,
    pub errores_sincronizacion: u32,
    pub archivos_transferidos: u32,
    pub archivos_crypto_transferidos: u32,
    pub archivos_borrados: u32,
    pub enlaces_detectados: u32,
    pub enlaces_creados: u32,
    pub enlaces_existentes: u32,
    pub enlaces_errores: u32,
    pub inicio: Instant,
}

impl SyncStats {
    pub fn new() -> Self {
        Self {
            elementos_procesados: 0,
            errores_sincronizacion: 0,
            archivos_transferidos: 0,
            archivos_crypto_transferidos: 0,
            archivos_borrados: 0,
            enlaces_detectados: 0,
            enlaces_creados: 0,
            enlaces_existentes: 0,
            enlaces_errores: 0,
            inicio: Instant::now(),
        }
    }
    
    pub fn tiempo_transcurrido(&self) -> Duration {
        self.inicio.elapsed()
    }
}

pub struct SyncEngine {
    config: Config,
    args: SyncArgs,
    stats: SyncStats,
}

impl SyncEngine {
    pub fn new(config: Config, args: SyncArgs) -> Self {
        Self {
            config,
            args,
            stats: SyncStats::new(),
        }
    }
    
    pub fn sincronizar(&mut self, logger: &mut Logger) -> Result<()> {
        log_info!(logger, "Iniciando proceso de sincronización en modo: {:?}", self.args.mode);
        
        // Verificar precondiciones
        self.verificar_precondiciones(logger)?;
        
        // Mostrar banner informativo
        self.mostrar_banner(logger);
        
        // Confirmar ejecución si no es --yes
        if !self.args.yes && !self.args.dry_run {
            if !crate::utils::confirmar_ejecucion()? {
                log_info!(logger, "Operación cancelada por el usuario");
                return Ok(());
            }
        }
        
        // Inicializar log
        self.inicializar_log(logger)?;
        
        // Procesar elementos
        self.procesar_elementos(logger)?;
        
        // Sincronizar Crypto si está habilitado
        if self.args.crypto {
            self.sincronizar_crypto(logger)?;
        } else {
            log_info!(logger, "Sincronización de directorio Crypto excluida");
        }
        
        // Manejar enlaces simbólicos
        self.manejar_enlaces_simbolicos(logger)?;
        
        log_success!(logger, "Sincronización completada");
        
        Ok(())
    }
    
    fn verificar_precondiciones(&self, logger: &mut Logger) -> Result<()> {
        let pcloud_mount = PathBuf::from(&self.config.paths.pcloud_mount_point);
        
        if !crate::utils::verificar_pcloud_montado(&pcloud_mount)? {
            log_error!(logger, "pCloud no está montado correctamente en: {}", pcloud_mount.display());
            return Err(anyhow::anyhow!("pCloud no montado"));
        }
        
        if !self.args.dry_run {
            let espacio_necesario = 500; // MB
            if !crate::utils::verificar_espacio_disco(&pcloud_mount, espacio_necesario)? {
                log_error!(logger, "Espacio insuficiente en disco");
                return Err(anyhow::anyhow!("Espacio insuficiente"));
            }
        }
        
        // Verificar conectividad (solo advertencia)
        if !crate::utils::verificar_conectividad_pcloud()? {
            log_warn!(logger, "No se pudo verificar la conectividad con pCloud");
        }
        
        log_info!(logger, "Todas las precondiciones verificadas correctamente");
        Ok(())
    }
    
    fn mostrar_banner(&self, logger: &mut Logger) {
        let pcloud_dir = self.config.get_pcloud_dir(&self.args.backup_dir_mode);
        
        log_info!(logger, "==========================================");
        
        match self.args.mode {
            SyncMode::Subir => {
                log_info!(logger, "MODO: SUBIR (Local → pCloud)");
                log_info!(logger, "ORIGEN: {}", self.config.paths.local_dir);
                log_info!(logger, "DESTINO: {}", pcloud_dir.display());
            }
            SyncMode::Bajar => {
                log_info!(logger, "MODO: BAJAR (pCloud → Local)");
                log_info!(logger, "ORIGEN: {}", pcloud_dir.display());
                log_info!(logger, "DESTINO: {}", self.config.paths.local_dir);
            }
        }
        
        log_info!(logger, "DIRECTORIO: {}", self.args.backup_dir_mode);
        
        if self.args.dry_run {
            log_info!(logger, "ESTADO: MODO SIMULACIÓN (no se realizarán cambios)");
        }
        
        if self.args.delete {
            log_info!(logger, "BORRADO: ACTIVADO (se eliminarán archivos obsoletos)");
        }
        
        if self.args.yes {
            log_info!(logger, "CONFIRMACIÓN: Automática (sin preguntar)");
        }
        
        if self.args.overwrite {
            log_info!(logger, "SOBRESCRITURA: ACTIVADA");
        } else {
            log_info!(logger, "MODO: SEGURO (--update activado)");
        }
        
        if self.args.crypto {
            log_info!(logger, "CRYPTO: INCLUIDO (se sincronizará directorio Crypto)");
        } else {
            log_info!(logger, "CRYPTO: EXCLUIDO (no se sincronizará directorio Crypto)");
        }
        
        if !self.args.items.is_empty() {
            log_info!(logger, "ELEMENTOS ESPECÍFICOS: {}", self.args.items.join(", "));
        }
        
        log_info!(logger, "EXCLUSIONES: {} patrones", self.config.exclusiones.len());
        
        if !self.args.exclude.is_empty() {
            log_info!(logger, "EXCLUSIONES CLI: {} patrones", self.args.exclude.len());
        }
        
        log_info!(logger, "==========================================");
    }
    
    fn inicializar_log(&self, logger: &mut Logger) -> Result<()> {
        let log_message = format!(
            "Sincronización iniciada - Modo: {:?}, Delete: {}, Dry-run: {}, Backup-dir: {}, Overwrite: {}, Checksum: {}, Sync Crypto: {}",
            self.args.mode,
            self.args.delete,
            self.args.dry_run,
            self.args.backup_dir_mode,
            self.args.overwrite,
            self.args.checksum,
            self.args.crypto
        );
        
        log_info!(logger, "{}", log_message);
        Ok(())
    }
    
    fn procesar_elementos(&mut self, logger: &mut Logger) -> Result<()> {
        let elementos = self.obtener_elementos_a_sincronizar()?;
        
        log_info!(logger, "Procesando {} elementos", elementos.len());
        
        for elemento in elementos {
            if let Err(e) = self.sincronizar_elemento(&elemento, logger) {
                log_error!(logger, "Error sincronizando {}: {}", elemento, e);
                self.stats.errores_sincronizacion += 1;
            } else {
                self.stats.elementos_procesados += 1;
            }
            log_info!(logger, "------------------------------------------");
        }
        
        Ok(())
    }
    
    fn obtener_elementos_a_sincronizar(&self) -> Result<Vec<String>> {
        if !self.args.items.is_empty() {
            return Ok(self.args.items.clone());
        }
        
        // Obtener la lista del TOML
        self.config.get_sync_list()
    }
    
    fn sincronizar_elemento(&mut self, elemento: &str, logger: &mut Logger) -> Result<()> {
        let pcloud_dir = self.config.get_pcloud_dir(&self.args.backup_dir_mode);
        let local_dir = PathBuf::from(&self.config.paths.local_dir);
        
        let (origen, destino, direccion) = match self.args.mode {
            SyncMode::Subir => {
                let origen = local_dir.join(elemento);
                let destino = pcloud_dir.join(elemento);
                (origen, destino, "LOCAL → PCLOUD (Subir)")
            }
            SyncMode::Bajar => {
                let origen = pcloud_dir.join(elemento);
                let destino = local_dir.join(elemento);
                (origen, destino, "PCLOUD → LOCAL (Bajar)")
            }
        };
        
        if !origen.exists() {
            return Err(anyhow::anyhow!("El origen no existe: {}", origen.display()));
        }
        
        log_info!(logger, "Sincronizando: {} ({})", elemento, direccion);
        
        // Crear directorio destino si no existe
        if let Some(parent) = destino.parent() {
            if !parent.exists() && !self.args.dry_run {
                std::fs::create_dir_all(parent)?;
                log_info!(logger, "Directorio creado: {}", parent.display());
            }
        }
        
        let mut cmd = self.construir_comando_rsync(&origen, &destino);
        log_debug!(logger, "Comando: {:?}", cmd);
        
        let output = cmd.output()?;
        
        if output.status.success() {
            let (transferidos, borrados) = self.analizar_salida_rsync(&output.stdout);
            self.stats.archivos_transferidos += transferidos;
            self.stats.archivos_borrados += borrados;
            
            log_success!(logger, "Sincronización completada: {} ({} archivos transferidos)", 
                elemento, transferidos);
                
            if borrados > 0 {
                log_info!(logger, "Archivos borrados: {}", borrados);
            }
        } else {
            let error_output = String::from_utf8_lossy(&output.stderr);
            log_error!(logger, "Error en rsync: {}", error_output);
            return Err(anyhow::anyhow!("rsync falló con código: {}", output.status));
        }
        
        Ok(())
    }
    
    fn construir_comando_rsync(&self, origen: &Path, destino: &Path) -> Command {
        let mut cmd = Command::new("rsync");
        
        cmd.arg("-av")
           .arg("--progress")
           .arg("--times")
           .arg("--whole-file")
           .arg("--itemize-changes");
           
        if !self.args.overwrite {
            cmd.arg("--update");
        }
        
        if self.args.dry_run {
            cmd.arg("--dry-run");
        }
        
        if self.args.delete {
            cmd.arg("--delete-delay");
        }
        
        if self.args.checksum {
            cmd.arg("--checksum");
        }
        
        if let Some(bwlimit) = &self.args.bwlimit {
            cmd.arg("--bwlimit").arg(bwlimit);
        }
        
        // Añadir exclusiones del TOML
        for exclusion in &self.config.exclusiones {
            cmd.arg("--exclude").arg(exclusion);
        }
        
        // Añadir exclusiones de línea de comandos
        for exclusion in &self.args.exclude {
            cmd.arg("--exclude").arg(exclusion);
        }
        
        // Añadir rutas
        let origen_str = if origen.is_dir() {
            format!("{}/", origen.display())
        } else {
            origen.display().to_string()
        };
        
        let destino_str = destino.display().to_string();
        
        cmd.arg(&origen_str).arg(&destino_str);
        
        cmd
    }
    
    fn analizar_salida_rsync(&self, output: &[u8]) -> (u32, u32) {
        let output_str = String::from_utf8_lossy(output);
        let mut transferidos = 0;
        let mut borrados = 0;
        
        for line in output_str.lines() {
            if line.starts_with('>') && (line.contains("f+++") || line.contains("f.st")) {
                transferidos += 1;
            } else if line.starts_with("*deleting") {
                borrados += 1;
            }
        }
        
        (transferidos, borrados)
    }
    
    fn sincronizar_crypto(&mut self, logger: &mut Logger) -> Result<()> {
        let crypto_sync = crate::crypto::CryptoSync::new(
            self.config.clone(), 
            PathBuf::from(&self.config.paths.local_dir)
        );
        
        if !crypto_sync.verificar_montaje_crypto(logger)? {
            return Err(anyhow::anyhow("Crypto no montado"));
        }
        
        crypto_sync.sincronizar_keepass(self.args.dry_run, logger)?;
        crypto_sync.sincronizar_crypto(
            &self.args.mode, 
            self.args.dry_run, 
            self.args.delete, 
            self.args.overwrite, 
            logger
        )?;
        
        Ok(())
    }
    
    fn manejar_enlaces_simbolicos(&mut self, logger: &mut Logger) -> Result<()> {
        let symlinks = crate::links::SymbolicLinks::new(
            PathBuf::from(&self.config.paths.local_dir),
            self.config.files.symlinks_file.clone()
        );
        
        let pcloud_dir = self.config.get_pcloud_dir(&self.args.backup_dir_mode);
        
        match self.args.mode {
            SyncMode::Subir => {
                let elementos = self.obtener_elementos_a_sincronizar()?;
                symlinks.generar_archivo_enlaces(
                    &elementos,
                    &pcloud_dir,
                    &mut self.stats,
                    logger
                )?;
            }
            SyncMode::Bajar => {
                symlinks.recrear_enlaces_desde_archivo(
                    &pcloud_dir,
                    &mut self.stats,
                    logger
                )?;
            }
        }
        
        Ok(())
    }
    
    pub fn mostrar_estadisticas(&self, logger: &mut Logger) {
        let tiempo = self.stats.tiempo_transcurrido();
        let segundos = tiempo.as_secs();
        
        let horas = segundos / 3600;
        let minutos = (segundos % 3600) / 60;
        let segundos = segundos % 60;
        
        let tiempo_formato = if horas > 0 {
            format!("{}h {}m {}s", horas, minutos, segundos)
        } else if minutos > 0 {
            format!("{}m {}s", minutos, segundos)
        } else {
            format!("{}s", segundos)
        };
        
        let velocidad_promedio = if segundos > 0 {
            self.stats.archivos_transferidos / segundos as u32
        } else {
            0
        };
        
        log_info!(logger, "==========================================");
        log_info!(logger, "RESUMEN DE SINCRONIZACIÓN");
        log_info!(logger, "==========================================");
        log_info!(logger, "Elementos procesados: {}", self.stats.elementos_procesados);
        log_info!(logger, "Archivos transferidos: {}", self.stats.archivos_transferidos);
        
        if self.args.crypto {
            log_info!(logger, "Archivos Crypto transferidos: {}", self.stats.archivos_crypto_transferidos);
        }
        
        if self.args.delete {
            log_info!(logger, "Archivos borrados en destino: {}", self.stats.archivos_borrados);
        }
        
        if !self.args.exclude.is_empty() {
            log_info!(logger, "Exclusiones CLI aplicadas: {} patrones", self.args.exclude.len());
        }
        
        log_info!(logger, "Enlaces detectados/guardados: {}", self.stats.enlaces_detectados);
        log_info!(logger, "Enlaces creados: {}", self.stats.enlaces_creados);
        log_info!(logger, "Enlaces existentes: {}", self.stats.enlaces_existentes);
        log_info!(logger, "Enlaces con errores: {}", self.stats.enlaces_errores);
        log_info!(logger, "Errores de sincronización: {}", self.stats.errores_sincronizacion);
        log_info!(logger, "Tiempo total: {}", tiempo_formato);
        log_info!(logger, "Velocidad promedio: {} archivos/segundo", velocidad_promedio);
        log_info!(logger, "Modo: {}", if self.args.dry_run { "SIMULACIÓN" } else { "EJECUCIÓN REAL" });
        log_info!(logger, "==========================================");
    }
}