# SyncB - Sincronización Bidireccional con pCloud

Script avanzado de sincronización bidireccional entre directorio local y pCloud Drive con capacidades de backup, manejo de enlaces simbólicos y sistema de logging.

## Características

- **Sincronización bidireccional**: Subir y bajar archivos entre local y pCloud
- **Manejo de enlaces simbólicos**: Registro y recreación automática
- **Sistema de logging**: Con rotación automática y niveles
- **Verificación de conectividad**: Check de pCloud montado y conectividad
- **Manejo de locks**: Previene ejecuciones simultáneas
- **Soporte múltiple**: Configuraciones por hostname
- **Directorio Crypto**: Soporte para directorio encriptado
- **Exclusiones configurables**: Patrones en TOML y CLI
- **Modo dry-run**: Simulación sin cambios
- **Verificación de espacio**: Check de espacio en disco
- **Timeout por operación**: Límite de tiempo configurable
- **Validación de rutas**: Prevención de path traversal
- **Permisos configurables**: Aplicación automática de permisos
- **Notificaciones**: Sistema de notificaciones
- **Estadísticas**: Reporte detallado de operaciones

## Requisitos

### Dependencias del sistema
- Python 3.8+
- rsync
- curl (opcional, para verificación de conectividad)

### Dependencias Python
```bash
pip install tomli tomli-w psutil


ARREGLAR 
------------------------------ 


cp syncb_config.toml ~/.config/syncb/config.toml
# Editar la configuración según necesidades

python -m pytest tests/

chmod +x syncb.py

git clone <repositorio>
cd syncb
 
# Sincronizar subiendo
./syncb.py --subir

# Sincronizar bajando
./syncb.py --bajar

# Simular sincronización (dry-run)
./syncb.py --subir --dry-run

# Sincronizar con eliminación de archivos obsoletos
./syncb.py --bajar --delete

# Sincronizar elementos específicos
./syncb.py --subir --item Documentos/ --item .config/

# Sincronizar con exclusiones
./syncb.py --bajar --exclude '*.tmp' --exclude 'temp/'

# Sincronizar incluyendo directorio Crypto
./syncb.py --subir --crypto

# Sincronizar con límite de ancho de banda
./syncb.py --subir --bwlimit 1000

# Sincronizar con timeout específico
./syncb.py --bajar --timeout 10

./syncb.py --help



syncb/
├── syncb.py                 # Script principal
├── syncb_config.toml        # Configuración ejemplo
├── README.md               # Este archivo
└── tests/                  # Tests unitarios
    ├── test_syncb.py
    └── test_config.py
    
    
    
    
--subir            Sincroniza desde local a pCloud
--bajar            Sincroniza desde pCloud a local
--delete           Elimina archivos obsoletos en destino
--dry-run          Simula sin hacer cambios
--item ELEMENTO    Sincroniza elemento específico (múltiple)
--yes              Ejecuta sin confirmación
--backup-dir       Usa directorio de backup de solo lectura
--exclude PATRON   Excluye por patrón (múltiple)
--overwrite        Sobrescribe archivos existentes
--checksum         Usa checksum para comparación
--bwlimit KB/s     Límite de velocidad
--timeout MIN      Timeout por operación (default: 30)
--force-unlock     Fuerza eliminación de lock
--crypto           Incluye directorio Crypto
--verbose          Modo verboso
--help             Muestra ayuda
