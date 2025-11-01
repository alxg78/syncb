use clap::Parser;

#[derive(Parser, Debug, Clone, Default)] // Añadido Clone y Default
#[command(
    name = "syncb",
    version = "1.0.0",
    author = "Tu Nombre",
    about = "Sincronización bidireccional entre directorio local y pCloud Drive",
    long_about = r#"
Script avanzado de sincronización bidireccional entre directorio local y pCloud Drive
con capacidades de backup, manejo de enlaces simbólicos y sistema de logging.

Ejemplos de uso:
  syncb --subir
  syncb --bajar --dry-run
  syncb --subir --delete --yes
  syncb --subir --item documentos/
  syncb --bajar --item configuracion.ini --item .local/bin --dry-run
  syncb --bajar --backup-dir --item documentos/ --yes
  syncb --subir --exclude '*.tmp' --exclude 'temp/'
  syncb --subir --overwrite     # Sobrescribe todos los archivos
  syncb --subir --bwlimit 1000  # Sincronizar subiendo con límite de 1MB/s
  syncb --subir --verbose       # Sincronizar con output verboso
  syncb --bajar --item Documentos/ --timeout 10  # Timeout corto de 10 minutos
  syncb --force-unlock   # Forzar desbloqueo si hay un lock obsoleto
  syncb --crypto         # Incluir directorio Crypto de la sincronización
"#
)]
pub struct Cli {
    /// Modo principal: subir desde local a pCloud
    #[arg(long)]
    pub subir: bool,

    /// Modo principal: bajar desde pCloud a local
    #[arg(long)]
    pub bajar: bool,

    /// Elimina en destino los archivos que no existan en origen
    #[arg(long)]
    pub delete: bool,

    /// Simula la operación sin hacer cambios reales
    #[arg(long)]
    pub dry_run: bool,

    /// Sincroniza solo el elemento especificado (archivo o directorio)
    #[arg(long, value_name = "ELEMENTO")]
    pub item: Option<Vec<String>>,

    /// No pregunta confirmación, ejecuta directamente
    #[arg(long)]
    pub yes: bool,

    /// Usa el directorio de backup de solo lectura (pCloud Backup)
    #[arg(long)]
    pub backup_dir: bool,

    /// Excluye archivos que coincidan con el patrón
    #[arg(long, value_name = "PATRON")]
    pub exclude: Vec<String>,

    /// Sobrescribe todos los archivos en destino (no usa --update)
    #[arg(long)]
    pub overwrite: bool,

    /// Fuerza comparación con checksum (más lento)
    #[arg(long)]
    pub checksum: bool,

    /// Limita la velocidad de transferencia (ej: 1000 para 1MB/s)
    #[arg(long, value_name = "KB/s")]
    pub bwlimit: Option<u32>,

    /// Límite de tiempo por operación (default: 30 minutos)
    #[arg(long, value_name = "MINUTOS")]
    pub timeout: Option<u32>,

    /// Forzar eliminación de lock
    #[arg(long)]
    pub force_unlock: bool,

    /// Incluye la sincronización del directorio Crypto
    #[arg(long)]
    pub crypto: bool,

    /// Habilita modo verboso para debugging
    #[arg(long)]
    pub verbose: bool,

    /// Items específicos para sincronizar (alias de --item)
    #[arg(last = true)]
    pub items: Option<Vec<String>>,
}

impl Cli {
    pub fn validate(&self) -> Result<(), String> {
        if self.subir && self.bajar {
            return Err("No puedes usar --subir y --bajar simultáneamente".to_string());
        }

        if !self.subir && !self.bajar && !self.force_unlock {
            return Err("Debes especificar --subir o --bajar".to_string());
        }

        Ok(())
    }

    pub fn get_mode(&self) -> SyncMode {
        if self.subir {
            SyncMode::Upload
        } else {
            SyncMode::Download
        }
    }

    pub fn get_backup_dir_mode(&self) -> BackupDirMode {
        if self.backup_dir {
            BackupDirMode::ReadOnly
        } else {
            BackupDirMode::Common
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SyncMode {
    Upload,
    Download,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BackupDirMode {
    Common,
    ReadOnly,
}
