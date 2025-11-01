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