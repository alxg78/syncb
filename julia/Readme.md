# SyncB - Sincronización Bidireccional Avanzada

Script avanzado de sincronización bidireccional entre directorio local y pCloud Drive con capacidades de backup, manejo de enlaces simbólicos y sistema de logging.

## Características

- ✅ Sincronización bidireccional (subir/bajar)
- ✅ Manejo de enlaces simbólicos
- ✅ Sistema de logging con rotación automática
- ✅ Verificación de conectividad con pCloud
- ✅ Manejo de locks para prevenir ejecuciones simultáneas
- ✅ Soporte para múltiples configuraciones por hostname
- ✅ Soporte para directorio Crypto encriptado
- ✅ Exclusiones configurables
- ✅ Modo dry-run (simulación)
- ✅ Verificación de espacio en disco
- ✅ Límite de tiempo por operación
- ✅ Validación de rutas para prevenir path traversal
- ✅ Estadísticas detalladas
- ✅ Notificaciones del sistema
- ✅ Manejo robusto de errores

## Requisitos

- Julia 1.6+
- rsync
- pCloud Drive instalado y configurado

## Instalación

1. Clona o descarga el proyecto
2. Instala las dependencias de Julia:
```bash
julia -e 'using Pkg; Pkg.add(["TOML", "ArgParse", "FilePathsBase"])'