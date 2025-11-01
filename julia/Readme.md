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


ARREGLAR 


julia --project src/syncb.jl --bajar --verbose --dry-run



# Sincronizar subiendo
julia syncb.jl --subir

# Sincronizar bajando
julia syncb.jl --bajar

# Modo simulación
julia syncb.jl --subir --dry-run

# Sincronizar elementos específicos
julia syncb.jl --subir --item Documentos/ --item .config/

# Con exclusión de patrones
julia syncb.jl --subir --exclude "*.tmp" --exclude "temp/"

# Con todas las opciones
julia syncb.jl --subir --delete --yes --crypto --verbose



# Sincronización completa con Crypto
julia syncb.jl --subir --crypto --yes

# Sincronización selectiva con límite de ancho de banda
julia syncb.jl --bajar --item proyectos/ --bwlimit 1000 --timeout 10

# Verificación sin cambios
julia syncb.jl --subir --dry-run --verbose




src/syncb.jl              # Script principal
syncb_config.toml     # Configuración unificada
README.md            # Documentación completa
test/                # Tests unitarios
  test_syncb.jl
  runtests.jl
