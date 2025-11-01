mod config;
mod args;
mod logging;
mod utils;
mod sync;
mod crypto;
mod links;

use anyhow::Result;
use std::path::PathBuf;
use std::env;

fn main() -> Result<()> {
    // Parsear argumentos
    let args = args::SyncArgs::parse();
    
    if args.help {
        mostrar_ayuda();
        return Ok(());
    }
    
    if let Err(e) = args.validate() {
        eprintln!("Error validando argumentos: {}", e);
        std::process::exit(1);
    }
    
    // Cargar configuración
    let config_path = obtener_ruta_configuracion()?;
    let config = config::Config::load(&config_path)?;
    
    // Inicializar logger
    let mut logger = logging::Logger::new(config.clone(), args.verbose, args.verbose)?;
    
    // Manejar force-unlock
    if args.force_unlock {
        let lock_file = obtener_archivo_lock(&config)?;
        utils::eliminar_lock(&lock_file)?;
        log_info!(logger, "Lock forzado eliminado");
        return Ok(());
    }
    
    // Establecer locking
    let lock_file = obtener_archivo_lock(&config)?;
    if !utils::establecer_lock(&lock_file, config.general.lock_timeout)? {
        log_error!(logger, "Ya hay una ejecución en progreso");
        std::process::exit(1);
    }
    
    // Registrar inicio
    log_info!(logger, "Sincronización iniciada");
    
    // Mostrar banner
    mostrar_banner(&args, &config, &mut logger);
    
    // Ejecutar sincronización
    let mut sync_engine = sync::SyncEngine::new(config.clone(), args.clone());
    let resultado = sync_engine.sincronizar(&mut logger);
    
    // Limpiar lock
    utils::eliminar_lock(&lock_file)?;
    
    // Mostrar estadísticas
    sync_engine.mostrar_estadisticas(&mut logger);
    
    // Manejar resultado
    match resultado {
        Ok(()) => {
            log_success!(logger, "Sincronización completada exitosamente");
            enviar_notificacion("Sincronización Completada", 
                "Sincronización finalizada con éxito", "info");
            Ok(())
        }
        Err(e) => {
            log_error!(logger, "Error durante la sincronización: {}", e);
            enviar_notificacion("Sincronización con Errores", 
                "Sincronización finalizada con errores", "error");
            Err(e)
        }
    }
}

fn obtener_ruta_configuracion() -> Result<String> {
    // Buscar en directorio actual primero
    let config_local = "syncb_config.toml";
    if std::path::Path::new(config_local).exists() {
        return Ok(config_local.to_string());
    }
    
    // Buscar en directorio del ejecutable
    if let Ok(exe_path) = env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let config_exe = exe_dir.join("syncb_config.toml");
            if config_exe.exists() {
                return Ok(config_exe.to_string_lossy().to_string());
            }
        }
    }
    
    // Buscar en home directory
    if let Some(home_dir) = dirs::home_dir() {
        let config_home = home_dir.join(".config").join("syncb").join("syncb_config.toml");
        if config_home.exists() {
            return Ok(config_home.to_string_lossy().to_string());
        }
    }
    
    Err(anyhow::anyhow!("No se pudo encontrar el archivo de configuración"))
}

fn obtener_archivo_lock(config: &config::Config) -> Result<PathBuf> {
    let tmp_dir = std::env::temp_dir();
    Ok(tmp_dir.join("syncb.lock"))
}

fn mostrar_banner(args: &args::SyncArgs, config: &config::Config, logger: &mut logging::Logger) {
    let pcloud_dir = config.get_pcloud_dir(&args.backup_dir_mode);
    
    log_info!(logger, "==========================================");
    
    match args.mode {
        args::SyncMode::Subir => {
            log_info!(logger, "MODO: SUBIR (Local → pCloud)");
            log_info!(logger, "ORIGEN: {}", config.paths.local_dir);
            log_info!(logger, "DESTINO: {}", pcloud_dir.display());
        }
        args::SyncMode::Bajar => {
            log_info!(logger, "MODO: BAJAR (pCloud → Local)");
            log_info!(logger, "ORIGEN: {}", pcloud_dir.display());
            log_info!(logger, "DESTINO: {}", config.paths.local_dir);
        }
    }
    
    log_info!(logger, "DIRECTORIO: {}", args.backup_dir_mode);
    
    if args.dry_run {
        log_info!(logger, "ESTADO: MODO SIMULACIÓN (no se realizarán cambios)");
    }
    
    if args.delete {
        log_info!(logger, "BORRADO: ACTIVADO (se eliminarán archivos obsoletos)");
    }
    
    if args.yes {
        log_info!(logger, "CONFIRMACIÓN: Automática (sin preguntar)");
    }
    
    if args.overwrite {
        log_info!(logger, "SOBRESCRITURA: ACTIVADA");
    } else {
        log_info!(logger, "MODO: SEGURO (--update activado)");
    }
    
    if args.crypto {
        log_info!(logger, "CRYPTO: INCLUIDO (se sincronizará directorio Crypto)");
    } else {
        log_info!(logger, "CRYPTO: EXCLUIDO (no se sincronizará directorio Crypto)");
    }
    
    if !args.items.is_empty() {
        log_info!(logger, "ELEMENTOS ESPECÍFICOS: {}", args.items.join(", "));
    }
    
    log_info!(logger, "==========================================");
}

fn mostrar_ayuda() {
    println!("Uso: syncb-rs [OPCIONES]");
    println!("");
    println!("Opciones PRINCIPALES (obligatorio una de ellas):");
    println!("  --subir            Sincroniza desde el directorio local a pCloud");
    println!("  --bajar            Sincroniza desde pCloud al directorio local");
    println!("");
    println!("Opciones SECUNDARIAS (opcionales):");
    println!("  --delete           Elimina en destino los archivos que no existan en origen");
    println!("  --dry-run          Simula la operación sin hacer cambios reales");
    println!("  --item ELEMENTO    Sincroniza solo el elemento especificado");
    println!("  --yes              No pregunta confirmación, ejecuta directamente");
    println!("  --backup-dir       Usa el directorio de backup de solo lectura");
    println!("  --exclude PATRON   Excluye archivos que coincidan con el patrón");
    println!("  --overwrite        Sobrescribe todos los archivos en destino");
    println!("  --checksum         Fuerza comparación con checksum");
    println!("  --bwlimit KB/s     Limita la velocidad de transferencia");
    println!("  --timeout MINUTOS  Límite de tiempo por operación");
    println!("  --force-unlock     Forzando eliminación de lock");
    println!("  --crypto           Incluye la sincronización del directorio Crypto");
    println!("  --verbose          Habilita modo verboso para debugging");
    println!("  --help             Muestra esta ayuda");
}

fn enviar_notificacion(titulo: &str, mensaje: &str, tipo: &str) {
    // Implementación simplificada de notificaciones
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("notify-send")
            .arg(titulo)
            .arg(mensaje)
            .output();
    }
    
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("osascript")
            .arg("-e")
            .arg(format!("display notification \"{}\" with title \"{}\"", mensaje, titulo))
            .output();
    }
    
    // Para otros sistemas, simplemente imprimir
    println!("🔔 {}: {}", titulo, mensaje);
}