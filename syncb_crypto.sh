#!/bin/bash

# Script de sincronización para archivos criptográficos
# Sincroniza entre directorio local y nube con verificaciones de montaje

set -o errexit  # Termina inmediatamente si algún comando falla
set -o nounset  # Termina si se usa alguna variable no definida
set -o pipefail # Falla si algún comando en una tubería falla

# Configuración de colores
readonly COLOR_RESET='\033[0m'
readonly COLOR_ROJO='\033[0;31m'
readonly COLOR_VERDE='\033[0;32m'
readonly COLOR_AMARILLO='\033[1;33m'
readonly COLOR_AZUL='\033[0;34m'

# Variables de configuración
readonly DIR_LOCAL="$HOME/Crypto"
readonly CLOUD_DIR="$HOME/pCloudDrive"
readonly DIR_REMOTO="$CLOUD_DIR/Crypto Folder"
readonly CLOUD_MOUNT_CHECK_FILE="mount.check"
readonly CLOUD_MOUNT_CHECK="$DIR_REMOTO/$CLOUD_MOUNT_CHECK_FILE"

# Variables de estado
DRY_RUN=0
DELETE=0
USE_CHECKSUM=0
OVERWRITE=0
EXCLUSIONES=""
EXCLUSIONES_CLI=()
ACCION=""

# Función de logging
log_error() {
    echo -e "${COLOR_ROJO}[ERROR]${COLOR_RESET} $*" >&2
}

log_info() {
    echo -e "${COLOR_VERDE}[INFO]${COLOR_RESET} $*"
}

log_debug() {
    if [ "${DEBUG:-0}" -eq 1 ]; then
        echo -e "${COLOR_AMARILLO}[DEBUG]${COLOR_RESET} $*"
    fi
}

log_cmd() {
    echo -e "${COLOR_AZUL}[COMANDO]${COLOR_RESET} $*"
}

# Mostrar ayuda
mostrar_ayuda() {
    cat <<EOF
Uso: $0 [OPCIONES]

Script de sincronización para archivos criptográficos.

Opciones exclusivas (requiere una):
  --subir          Sincroniza local -> nube
  --bajar          Sincroniza nube -> local

Opciones generales:
  --dry-run        Simular sin realizar cambios reales
  --delete         Habilitar eliminación de archivos obsoletos
  --checksum       Usar verificación por checksum (más lento)
  --overwrite      Sobrescribir archivos existentes
  --exclude-from   Archivo con patrones de exclusión
  --exclude        Patrón de exclusión (puede usarse múltiples veces)
  --debug          Habilitar modo debug
  --help           Mostrar esta ayuda

Ejemplos:
  $0 --subir --delete
  $0 --bajar --exclude="*.tmp" --exclude="log/"
EOF
}

# Verificar que el punto de montaje esté disponible
verificar_montaje() {
    if [ ! -f "$CLOUD_MOUNT_CHECK" ]; then
        log_error "El volumen no está montado o el archivo de verificación no existe"
        log_error "Por favor, desbloquea/monta la unidad en: \"$DIR_REMOTO\""
        exit 1
    fi
    log_info "Verificación de montaje exitosa"
}

# Construir opciones de rsync
construir_opciones_rsync() {
    log_debug "Construyendo opciones de rsync..."

    RSYNC_OPTS=(
        --recursive
        --verbose
        --times
        --progress
        --whole-file
        --itemize-changes
    )

    [ $OVERWRITE -eq 0 ] && RSYNC_OPTS+=(--update)
    [ $DRY_RUN -eq 1 ] && RSYNC_OPTS+=(--dry-run)
    [ $DELETE -eq 1 ] && RSYNC_OPTS+=(--delete-delay)
    [ $USE_CHECKSUM -eq 1 ] && RSYNC_OPTS+=(--checksum)

    # Proteger permanentemente el archivo de verificación de montaje contra eliminación
    #RSYNC_OPTS+=(--filter="protect $CLOUD_MOUNT_CHECK_FILE")

    # Excluir el archivo de verificación de montaje de la transferencia
    RSYNC_OPTS+=(--exclude="$CLOUD_MOUNT_CHECK_FILE")

    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        RSYNC_OPTS+=(--exclude-from="$EXCLUSIONES")
    fi

    if [ ${#EXCLUSIONES_CLI[@]} -gt 0 ]; then
        for patron in "${EXCLUSIONES_CLI[@]}"; do
            RSYNC_OPTS+=(--exclude="$patron")
        done
        log_info "Exclusiones por CLI aplicadas: ${#EXCLUSIONES_CLI[@]} patrones"
    fi

    log_debug "Opciones finales de rsync: ${RSYNC_OPTS[*]}"
}

# Procesar estadísticas de rsync
procesar_estadisticas() {
    local output="$1"
    echo "$output"

    local transferidos=$(echo "$output" | grep -E '^sent.*received' | awk '{print $2}')
    local borrados=$(echo "$output" | grep -E 'deleted' | awk '{print $2}')

    log_info "Archivos transferidos: ${transferidos:-0}"
    [ "${borrados:-0}" -gt 0 ] && log_info "Archivos eliminados: $borrados"
}

# Sincronizar directorios
sincronizar() {
    local origen="$1"
    local destino="$2"

    log_info "Iniciando sincronización: $origen -> $destino"

    # Mostrar el comando completo que se ejecutará
    log_cmd "rsync ${RSYNC_OPTS[*]} \"$origen/\" \"$destino/\""

    local output
    output=$(rsync "${RSYNC_OPTS[@]}" "$origen/" "$destino/" 2>&1)

    procesar_estadisticas "$output"
}

# Procesar argumentos
procesar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --subir)
            [ -n "$ACCION" ] && {
                log_error "Opciones --subir y --bajar son mutuamente excluyentes"
                exit 1
            }
            ACCION="subir"
            ;;
        --bajar)
            [ -n "$ACCION" ] && {
                log_error "Opciones --subir y --bajar son mutuamente excluyentes"
                exit 1
            }
            ACCION="bajar"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --delete)
            DELETE=1
            ;;
        --checksum)
            USE_CHECKSUM=1
            ;;
        --overwrite)
            OVERWRITE=1
            ;;
        --exclude-from)
            EXCLUSIONES="$2"
            shift
            ;;
        --exclude)
            EXCLUSIONES_CLI+=("$2")
            shift
            ;;
        --debug)
            DEBUG=1
            ;;
        --help)
            mostrar_ayuda
            exit 0
            ;;
        *)
            log_error "Opción desconocida: $1"
            mostrar_ayuda
            exit 1
            ;;
        esac
        shift
    done

    # Validar acción seleccionada
    if [ -z "$ACCION" ]; then
        log_error "Debe especificar --subir o --bajar"
        mostrar_ayuda
        exit 1
    fi
}

# Función principal
main() {
    procesar_argumentos "$@"

    verificar_montaje
    construir_opciones_rsync

    case $ACCION in
    subir)
        sincronizar "$DIR_LOCAL" "$DIR_REMOTO"
        ;;
    bajar)
        sincronizar "$DIR_REMOTO" "$DIR_LOCAL"
        ;;
    esac

    log_info "Sincronización completada exitosamente"
}

# Ejecutar función principal
main "$@"
