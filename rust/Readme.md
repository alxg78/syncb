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