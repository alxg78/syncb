#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# Debug / Fixed sync script focused on showing the exact rsync command and diagnosing why rsync
# options might contain the literal word "rsync" repeated.
#
# Usage examples:
#   ./sync_bidireccional_debug_final.sh --subir --item Documentos --dry-run
#   ./sync_bidireccional_debug_final.sh --bajar --item Documentos --dry-run

PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"
LOCAL_DIR="${HOME}"
PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use FQDN as requested
if command -v hostname >/dev/null 2>&1; then
    HOSTNAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
else
    HOSTNAME="unknown"
fi
HOSTNAME_RTVA="feynman.sobremesa.dnf"

# Options
MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"
USE_CHECKSUM=0

LOG_FILE="${HOME}/sync_bidireccional_debug.log"
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

# Basic helpers
echo_stderr() { printf "%s\n" "$*" >&2; }

mostrar_ayuda() {
    cat <<'EOF'
Uso: sync_bidireccional_debug_final.sh --subir|--bajar [--item PATH] [--dry-run] [--yes] [--delete] [--overwrite] [--checksum]

Este script es una versión depuradora que:
 - Construye RSYNC_OPTS de forma segura (sin introducir la palabra 'rsync' como opción).
 - Valida el contenido de RSYNC_OPTS (si contiene 'rsync', aborta e imprime diagnóstico).
 - Muestra exactamente el comando que se va a ejecutar (con escaping %q).
 - Ejecuta rsync usando array expansion (no evaluación textual).
EOF
}

# parse args (simple)
if [ $# -eq 0 ]; then
    echo_stderr "ERROR: Debes especificar --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --subir) MODO="subir"; shift;;
        --bajar) MODO="bajar"; shift;;
        --item) ITEM_ESPECIFICO="$2"; shift 2;;
        --dry-run) DRY_RUN=1; shift;;
        --yes) YES=1; shift;;
        --delete) DELETE=1; shift;;
        --overwrite) OVERWRITE=1; shift;;
        --checksum) USE_CHECKSUM=1; shift;;
        --backup-dir) BACKUP_DIR_MODE="readonly"; shift;;
        --help) mostrar_ayuda; exit 0;;
        *) echo_stderr "Opción desconocida: $1"; mostrar_ayuda; exit 1;;
    esac
done

[ -n "$MODO" ] || { echo_stderr "ERROR: Debes indicar --subir o --bajar"; exit 1; }

# Find config files (as original, but simple)
find_config_files() {
    local lista_por_defecto="sync_bidireccional_directorios.ini"
    local lista_especifica="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"

    if [ -f "${SCRIPT_DIR}/${lista_especifica}" ]; then
        LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_especifica}"
    elif [ -f "./${lista_especifica}" ]; then
        LISTA_SINCRONIZACION="./${lista_especifica}"
    elif [ -f "${SCRIPT_DIR}/${lista_por_defecto}" ]; then
        LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_por_defecto}"
    elif [ -f "./${lista_por_defecto}" ]; then
        LISTA_SINCRONIZACION="./${lista_por_defecto}"
    else
        LISTA_SINCRONIZACION=""
    fi

    if [ -f "${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini"
    elif [ -f "./sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="./sync_bidireccional_exclusiones.ini"
    else
        EXCLUSIONES=""
    fi
}

# Build RSYNC_OPTS safely (NO 'rsync' strings here)
construir_opciones_rsync() {
    RSYNC_OPTS=()
    # Core options
    RSYNC_OPTS+=(--recursive --verbose --times --progress --whole-file --no-links)

    # Behavior flags
    [ $OVERWRITE -eq 0 ] && RSYNC_OPTS+=(--update)
    [ $DRY_RUN -eq 1 ] && RSYNC_OPTS+=(--dry-run)
    [ $DELETE -eq 1 ] && RSYNC_OPTS+=(--delete-delay)
    [ $USE_CHECKSUM -eq 1 ] && RSYNC_OPTS+=(--checksum)

    # Load excludes file if present; each line is a pattern
    if [ -n "${EXCLUSIONES:-}" ] && [ -f "$EXCLUSIONES" ]; then
        while IFS= read -r linea || [ -n "$linea" ]; do
            # skip empty lines and comments
            case "$linea" in
                ''|\#*) continue;;
            esac
            RSYNC_OPTS+=(--exclude="$linea")
        done < "$EXCLUSIONES"
    fi
}

# Validation: ensure no element accidentally contains the word 'rsync'
validate_rsync_opts() {
    local i
    for i in "${RSYNC_OPTS[@]:-}"; do
        # if the literal string 'rsync' appears anywhere, it's suspicious
        if printf '%s\n' "$i" | grep -qi 'rsync'; then
            echo_stderr "ERROR: RSYNC_OPTS contiene un elemento sospechoso con 'rsync': '$i'"
            echo_stderr "Contenido actual de RSYNC_OPTS (declare -p):"
            declare -p RSYNC_OPTS 2>/dev/null || printf '%s\n' "${RSYNC_OPTS[@]}"
            return 1
        fi
    done
    return 0
}

# Print the command array in a safe, fully-escaped form
print_cmd_array() {
    local -n _arr=$1
    printf "Comando a ejecutar:\n"
    for el in "${_arr[@]}"; do
        printf "%q " "$el"
    done
    printf "\n"
}

# Resolve --item to be relative to $HOME if given absolute inside HOME
resolver_item_relativo() {
    local item="$1"
    if [ -z "$item" ]; then
        echo ""
        return
    fi
    if [[ "$item" = /* ]]; then
        # absolute path; ensure it's under $LOCAL_DIR
        case "$item" in
            "$LOCAL_DIR"/*) echo "${item#$LOCAL_DIR/}" ;;
            "$LOCAL_DIR") echo "." ;;
            *) echo_stderr "ERROR: --item absoluto fuera de \$HOME: $item"; exit 1 ;;
        esac
    else
        echo "$item"
    fi
}

# Sync one element (prints and validates)
sincronizar_elemento_debug() {
    local elemento="$1"
    local PCLOUD_DIR origen destino
    PCLOUD_DIR="$( [ "$BACKUP_DIR_MODE" = "readonly" ] && echo "${PCLOUD_BACKUP_READONLY}" || echo "${PCLOUD_BACKUP_COMUN}" )"

    if [ "$MODO" = "subir" ]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${PCLOUD_DIR}/${elemento}"
    else
        origen="${PCLOUD_DIR}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
    fi

    [ -e "$origen" ] || { echo_stderr "ADVERTENCIA: No existe el origen: $origen"; return 1; }

    if [ -d "$origen" ]; then
        origen="${origen%/}/"
        destino="${destino%/}/"
    fi

    construir_opciones_rsync

    # Validate RSYNC_OPTS
    if ! validate_rsync_opts; then
        echo_stderr "Abortando por contenido inválido en RSYNC_OPTS."
        return 2
    fi

    # Build command array safely
    cmd=(rsync)
    for opt in "${RSYNC_OPTS[@]}"; do
        cmd+=("$opt")
    done
    cmd+=("--")
    cmd+=("$origen" "$destino")

    # Print what will be executed
    print_cmd_array cmd

    # Also print RSYNC_OPTS for extra clarity
    echo "declare -p RSYNC_OPTS:"
    declare -p RSYNC_OPTS 2>/dev/null || printf '%s\n' "${RSYNC_OPTS[@]}"

    # Execute rsync (the array will handle spaces correctly). Capture output.
    echo "Ejecutando rsync..."
    if "${cmd[@]}"; then
        echo "✓ Sincronización (debug) completada para: $elemento"
        return 0
    else
        local rc=$?
        echo_stderr "✗ rsync finalizó con código $rc"
        return $rc
    fi
}

# MAIN (simpler than the full original; this script is for debugging rsync invocation)
find_config_files

if [ -n "$ITEM_ESPECIFICO" ]; then
    REL_ITEM="$(resolver_item_relativo "$ITEM_ESPECIFICO")"
    echo "DEBUG: Modo: $MODO, Item: $REL_ITEM, Dry-run: $DRY_RUN"
    sincronizar_elemento_debug "$REL_ITEM"
    exit $?
else
    # If no item given, read list file
    if [ -z "${LISTA_SINCRONIZACION:-}" ]; then
        echo_stderr "No se proporcionó --item y no se encontró lista de sincronización."
        exit 1
    fi
    while IFS= read -r linea || [ -n "$linea" ]; do
        [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue
        sincronizar_elemento_debug "$linea" || true
    done < "$LISTA_SINCRONIZACION"
fi
