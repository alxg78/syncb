#!/bin/bash
#
# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud

# ==========================================
# Configuración
# ==========================================
PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"
LOCAL_DIR="${HOME}"
PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname)
HOSTNAME_RTVA="feynman.rtva.dnf"

LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="$HOME/sync_bidireccional.log"
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"
VERBOSE=0

# ==========================================
# Colores
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==========================================
# Gestión de logs y mensajes
# ==========================================
log() {
    local level="$1"; shift
    local msg="$*"
    echo "$(date '+%F %T') [$level] $msg" >> "$LOG_FILE"
    case "$level" in
        ERROR|WARN|SUMMARY)
            echo -e "${RED}$msg${NC}"
            ;;
        INFO|DEBUG)
            [ $VERBOSE -eq 1 ] && echo -e "${BLUE}$msg${NC}"
            ;;
    esac
}

# ==========================================
# Limpieza de temporales
# ==========================================
TMP_FILES=()
cleanup() { rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT

# ==========================================
# Funciones principales
# ==========================================
get_pcloud_dir() {
    [ "$BACKUP_DIR_MODE" = "readonly" ] && echo "$PCLOUD_BACKUP_READONLY" || echo "$PCLOUD_BACKUP_COMUN"
}

find_config_files() {
    local lista_por_defecto="sync_bidireccional_directorios.ini"
    local lista_especifica="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        if [ -f "${SCRIPT_DIR}/${lista_especifica}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_especifica}"
        elif [ -f "./${lista_especifica}" ]; then
            LISTA_SINCRONIZACION="./${lista_especifica}"
        else
            log ERROR "No se encontró ${lista_especifica}"
            exit 1
        fi
    else
        if [ -f "${SCRIPT_DIR}/${lista_por_defecto}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_por_defecto}"
        elif [ -f "./${lista_por_defecto}" ]; then
            LISTA_SINCRONIZACION="./${lista_por_defecto}"
        fi
    fi
    if [ -f "${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini"
    elif [ -f "./sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="./sync_bidireccional_exclusiones.ini"
    fi
}

mostrar_ayuda() {
    echo "Uso: $0 --subir|--bajar [opciones]"
    echo "Opciones:"
    echo "  --delete       Borrar ficheros en destino que no existen en origen"
    echo "  --dry-run      Simulación sin cambios"
    echo "  --item <path>  Sincronizar solo un elemento"
    echo "  --yes          No preguntar confirmación"
    echo "  --backup-dir   Usar directorio solo-lectura de backup"
    echo "  --overwrite    Sobrescribir aunque fecha sea más nueva"
    echo "  --verbose      Mostrar detalles adicionales"
    echo "  --help         Mostrar esta ayuda"
}

verificar_pcloud_montado() {
    local PCLOUD_DIR=$(get_pcloud_dir)
    if [ ! -d "$PCLOUD_MOUNT_POINT" ]; then
        log ERROR "No existe $PCLOUD_MOUNT_POINT"
        exit 1
    fi
    if [ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]; then
        log ERROR "pCloud no montado correctamente"
        exit 1
    fi
    if ! mount | grep -q "pCloud\|pcloud"; then
        log ERROR "pCloud no aparece montado"
        exit 1
    fi
    if [ ! -d "$PCLOUD_DIR" ]; then
        log ERROR "No existe $PCLOUD_DIR"
        exit 1
    fi
    if [ $DRY_RUN -eq 0 ] && [ "$BACKUP_DIR_MODE" = "comun" ]; then
        local test_file="${PCLOUD_DIR}/.test_write_$$"
        if ! touch "$test_file" 2>/dev/null; then
            log ERROR "No se puede escribir en $PCLOUD_DIR"
            exit 1
        fi
        rm -f "$test_file"
    fi
    log INFO "Verificación de pCloud OK"
}

mostrar_banner() {
    local PCLOUD_DIR=$(get_pcloud_dir)
    echo "=========================================="
    if [ "$MODO" = "subir" ]; then
        echo "MODO: SUBIR (${LOCAL_DIR} → ${PCLOUD_DIR})"
    else
        echo "MODO: BAJAR (${PCLOUD_DIR} → ${LOCAL_DIR})"
    fi
    echo "=========================================="
}

confirmar_ejecucion() {
    [ $YES -eq 1 ] && return
    read -p "¿Desea continuar? [s/N]: " r
    [[ ! "$r" =~ ^[sS]$ ]] && exit 0
}

inicializar_log() {
    touch "$LOG_FILE"
    echo "==== Sincronización iniciada: $(date) ====" >> "$LOG_FILE"
}

verificar_dependencias() {
    command -v rsync >/dev/null || { log ERROR "Falta rsync"; exit 1; }
}

verificar_archivos_configuracion() {
    if [ -z "$ITEM_ESPECIFICO" ] && [ -z "$LISTA_SINCRONIZACION" ]; then
        log ERROR "Falta archivo de lista de sincronización"
        exit 1
    fi
}

construir_opciones_rsync() {
    local o=(--recursive --verbose --times --checksum --progress --whole-file --no-links)
    [ $OVERWRITE -eq 0 ] && o+=(--update)
    [ $DRY_RUN -eq 1 ] && o+=(--dry-run)
    [ $DELETE -eq 1 ] && o+=(--delete-delay)
    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        while IFS= read -r l; do
            [[ -z "$l" || "$l" =~ ^[[:space:]]*# ]] && continue
            o+=(--exclude="$l")
        done < "$EXCLUSIONES"
    fi
    echo "${o[@]}"
}

generar_archivo_enlaces() {
    local archivo_enlaces="$1"
    local PCLOUD_DIR=$(get_pcloud_dir)
    > "$archivo_enlaces"

    registrar_enlace() {
        local enlace="$1"
        [ ! -L "$enlace" ] && return
        local ruta_relativa
        ruta_relativa=$(realpath --relative-to="${LOCAL_DIR}" "$enlace")
        local destino
        destino=$(readlink "$enlace")
        printf "%s\t%s\n" "$ruta_relativa" "$destino" >> "$archivo_enlaces"
        log DEBUG "Registrado enlace: $ruta_relativa -> $destino"
    }

    buscar_enlaces_en_directorio() {
        find "$1" -type l | while read -r e; do registrar_enlace "$e"; done
    }

    if [ -n "$ITEM_ESPECIFICO" ]; then
        local ruta="${LOCAL_DIR}/${ITEM_ESPECIFICO}"
        [ -L "$ruta" ] && registrar_enlace "$ruta"
        [ -d "$ruta" ] && buscar_enlaces_en_directorio "$ruta"
    else
        while IFS= read -r e; do
            [[ -n "$e" && ! "$e" =~ ^[[:space:]]*# ]] || continue
            local ruta="${LOCAL_DIR}/${e}"
            [ -L "$ruta" ] && registrar_enlace "$ruta"
            [ -d "$ruta" ] && buscar_enlaces_en_directorio "$ruta"
        done < "$LISTA_SINCRONIZACION"
    fi

    if [ -s "$archivo_enlaces" ]; then
        local opciones
        opciones=$(construir_opciones_rsync)
        if [ $DRY_RUN -eq 1 ]; then
            log INFO "[SIMULACIÓN] rsync $opciones $archivo_enlaces ${PCLOUD_DIR}/${SYMLINKS_FILE}"
        else
            rsync $opciones "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"
            log INFO "Archivo de enlaces sincronizado"
        fi
    else
        log INFO "No se encontraron enlaces simbólicos"
    fi
}

recrear_enlaces_desde_archivo() {
    local PCLOUD_DIR=$(get_pcloud_dir)
    local origen="${PCLOUD_DIR}/${SYMLINKS_FILE}"
    local localfile="${LOCAL_DIR}/${SYMLINKS_FILE}"
    [ -f "$origen" ] && cp "$origen" "$localfile"
    [ ! -f "$localfile" ] && return
    while IFS=$'\t' read -r ruta destino; do
        [ -z "$ruta" ] || [ -z "$destino" ] && continue
        local completo="${LOCAL_DIR}/${ruta}"
        mkdir -p "$(dirname "$completo")"
        if [ $DRY_RUN -eq 1 ]; then
            log INFO "[SIMULACIÓN] ln -sfn '$destino' '$completo'"
        else
            ln -sfn "$destino" "$completo"
            log DEBUG "Recreado enlace: $completo -> $destino"
        fi
    done < "$localfile"
    [ $DRY_RUN -eq 0 ] && rm -f "$localfile"
}

sincronizar_elemento() {
    local elemento="$1" opciones="$2" PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)
    if [ "$MODO" = "subir" ]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${PCLOUD_DIR}/${elemento}"
    else
        origen="${PCLOUD_DIR}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
    fi
    [ ! -e "$origen" ] && { log WARN "No existe $origen"; return; }
    [ -d "$origen" ] && origen="${origen}/"
    mkdir -p "$(dirname "$destino")"
    log INFO "Sincronizando: $elemento"
    rsync $opciones "$origen" "$destino"
}

sincronizar() {
    local opciones
    opciones=$(construir_opciones_rsync)
    mostrar_banner
    verificar_pcloud_montado
    [ $DRY_RUN -eq 0 ] && confirmar_ejecucion
    if [ -n "$ITEM_ESPECIFICO" ]; then
        sincronizar_elemento "$ITEM_ESPECIFICO" "$opciones"
    else
        while IFS= read -r l; do
            [[ -n "$l" && ! "$l" =~ ^[[:space:]]*# ]] && sincronizar_elemento "$l" "$opciones"
        done < "$LISTA_SINCRONIZACION"
    fi
    if [ "$MODO" = "subir" ]; then
        local tmpfile
        tmpfile=$(mktemp)
        TMP_FILES+=("$tmpfile")
        generar_archivo_enlaces "$tmpfile"
    else
        recrear_enlaces_desde_archivo
    fi
    log SUMMARY "Sincronización finalizada"
}

# ==========================================
# Procesar argumentos
# ==========================================
[ $# -eq 0 ] && { mostrar_ayuda; exit 1; }
while [[ $# -gt 0 ]]; do
    case $1 in
        --subir) MODO="subir";;
        --bajar) MODO="bajar";;
        --delete) DELETE=1;;
        --dry-run) DRY_RUN=1;;
        --item) ITEM_ESPECIFICO="$2"; shift;;
        --yes) YES=1;;
        --backup-dir) BACKUP_DIR_MODE="readonly";;
        --overwrite) OVERWRITE=1;;
        --verbose) VERBOSE=1;;
        --help) mostrar_ayuda; exit 0;;
        *) log ERROR "Opción desconocida: $1"; exit 1;;
    esac
    shift
done

[ -z "$MODO" ] && { log ERROR "Falta --subir o --bajar"; exit 1; }

# ==========================================
# Ejecución
# ==========================================
verificar_dependencias
find_config_files
verificar_archivos_configuracion
inicializar_log
sincronizar

