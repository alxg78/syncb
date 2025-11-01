# syncb-rs - Sincronización Bidireccional con pCloud

Sincronización avanzada bidireccional entre directorio local y pCloud Drive con capacidades de backup, manejo de enlaces simbólicos y sistema de logging.

## Características

- ✅ Sincronización bidireccional (subir/bajar)
- ✅ Manejo de enlaces simbólicos
- ✅ Sistema de logging con rotación automática
- ✅ Verificación de conectividad con pCloud
- ✅ Manejo de locks para ejecuciones simultáneas
- ✅ Soporte para múltiples configuraciones por hostname
- ✅ Soporte para directorio Crypto encriptado
- ✅ Exclusiones configurables
- ✅ Modo dry-run para simulaciones
- ✅ Verificación de espacio en disco
- ✅ Límite de tiempo por operación
- ✅ Validación de rutas contra path traversal
- ✅ Notificaciones del sistema
- ✅ Estadísticas detalladas
- ✅ Manejo robusto de errores

## Instalación

### Requisitos

- Rust 1.70+ 
- pCloud Drive instalado y configurado
- rsync disponible en el sistema

### Compilación

```bash
git clone <repositorio>
cd syncb-rs
cargo build --release



----------------------------------------------
ARREGAR
----------------------------------------------
cargo test

cargo install --path .


# Subir archivos a pCloud
syncb --subir

# Bajar archivos desde pCloud
syncb --bajar

# Simular sincronización
syncb --subir --dry-run

# Sincronizar con eliminación de archivos obsoletos
syncb --subir --delete

# Sincronizar elementos específicos
syncb --subir --item Documentos/ --item .config/

# Excluir patrones
syncb --subir --exclude "*.tmp" --exclude "temp/"

# Incluir directorio Crypto
syncb --subir --crypto

# Límite de ancho de banda
syncb --subir --bwlimit 1000  # 1MB/s

# Timeout personalizado
syncb --subir --timeout 10  # 10 minutos

cargo fmt

syncb --help

cargo build

cargo clippy


syncb-rs/
├── Cargo.toml
├── config.toml
├── README.md
├── src/
│   ├── main.rs
│   ├── config.rs
│   ├── sync.rs
│   ├── logging.rs
│   ├── lock.rs
│   ├── crypto.rs
│   ├── cli.rs
│   ├── stats.rs
│   └── error.rs
└── tests/
    └── integration_tests.rs





~/
├── pCloudDrive/                 # Punto de montaje de pCloud
│   ├── Backups/
│   │   └── Backup_Comun/       # Backup común
│   ├── pCloud Backup/          # Backup de solo lectura  
│   └── Crypto Folder/          # Directorio Crypto
└── Crypto/                     # Directorio Crypto local
    └── ficheros_sensibles/
        └── Keepass2Android/
