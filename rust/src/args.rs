use clap::{Arg, Command};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub enum SyncMode {
    Subir,
    Bajar,
}

#[derive(Debug, Clone)]
pub struct SyncArgs {
    pub mode: SyncMode,
    pub delete: bool,
    pub dry_run: bool,
    pub items: Vec<String>,
    pub yes: bool,
    pub backup_dir_mode: BackupDirMode,
    pub exclude: Vec<String>,
    pub overwrite: bool,
    pub checksum: bool,
    pub bwlimit: Option<String>,
    pub timeout: Option<u64>,
    pub force_unlock: bool,
    pub crypto: bool,
    pub verbose: bool,
    pub help: bool,
}

impl SyncArgs {
    pub fn parse() -> Self {
        let matches = Command::new("syncb-rs")
            .about("Sincronización bidireccional entre directorio local y pCloud")
            .arg(Arg::new("subir")
                .long("subir")
                .help("Sincroniza desde el directorio local a pCloud")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("bajar")
                .long("bajar")
                .help("Sincroniza desde pCloud al directorio local")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("delete")
                .long("delete")
                .help("Elimina en destino los archivos que no existan en origen")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("dry-run")
                .long("dry-run")
                .help("Simula la operación sin hacer cambios reales")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("item")
                .long("item")
                .help("Sincroniza solo el elemento especificado")
                .action(clap::ArgAction::Append)
                .value_name("ELEMENTO"))
            .arg(Arg::new("yes")
                .long("yes")
                .help("No pregunta confirmación, ejecuta directamente")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("backup-dir")
                .long("backup-dir")
                .help("Usa el directorio de backup de solo lectura")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("exclude")
                .long("exclude")
                .help("Excluye archivos que coincidan con el patrón")
                .action(clap::ArgAction::Append)
                .value_name("PATRON"))
            .arg(Arg::new("overwrite")
                .long("overwrite")
                .help("Sobrescribe todos los archivos en destino")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("checksum")
                .long("checksum")
                .help("Fuerza comparación con checksum")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("bwlimit")
                .long("bwlimit")
                .help("Limita la velocidad de transferencia (ej: 1000 para 1MB/s)")
                .value_name("KB/s"))
            .arg(Arg::new("timeout")
                .long("timeout")
                .help("Límite de tiempo por operación (default: 30)")
                .value_name("MINUTOS"))
            .arg(Arg::new("force-unlock")
                .long("force-unlock")
                .help("Forzando eliminación de lock")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("crypto")
                .long("crypto")
                .help("Incluye la sincronización del directorio Crypto")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("verbose")
                .long("verbose")
                .help("Habilita modo verboso para debugging")
                .action(clap::ArgAction::SetTrue))
            .arg(Arg::new("help")
                .long("help")
                .short('h')
                .help("Muestra esta ayuda")
                .action(clap::ArgAction::SetTrue))
            .get_matches();

        // Determinar modo
        let mode = if matches.get_flag("subir") {
            SyncMode::Subir
        } else if matches.get_flag("bajar") {
            SyncMode::Bajar
        } else {
            SyncMode::Subir // Por defecto
        };

        // Verificar que no se usen ambos modos
        if matches.get_flag("subir") && matches.get_flag("bajar") {
            eprintln!("Error: No puedes usar --subir y --bajar simultáneamente");
            std::process::exit(1);
        }

        let backup_dir_mode = if matches.get_flag("backup-dir") {
            BackupDirMode::ReadOnly
        } else {
            BackupDirMode::Comun
        };

        SyncArgs {
            mode,
            delete: matches.get_flag("delete"),
            dry_run: matches.get_flag("dry-run"),
            items: matches.get_many::<String>("item")
                .map(|vals| vals.map(|s| s.to_string()).collect())
                .unwrap_or_default(),
            yes: matches.get_flag("yes"),
            backup_dir_mode,
            exclude: matches.get_many::<String>("exclude")
                .map(|vals| vals.map(|s| s.to_string()).collect())
                .unwrap_or_default(),
            overwrite: matches.get_flag("overwrite"),
            checksum: matches.get_flag("checksum"),
            bwlimit: matches.get_one::<String>("bwlimit").cloned(),
            timeout: matches.get_one::<String>("timeout")
                .and_then(|s| s.parse().ok()),
            force_unlock: matches.get_flag("force-unlock"),
            crypto: matches.get_flag("crypto"),
            verbose: matches.get_flag("verbose"),
            help: matches.get_flag("help"),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.help {
            return Ok(());
        }

        // Validaciones adicionales pueden ir aquí
        if let Some(bwlimit) = &self.bwlimit {
            if bwlimit.parse::<u32>().is_err() {
                return Err("bwlimit debe ser un número".to_string());
            }
        }

        Ok(())
    }
}