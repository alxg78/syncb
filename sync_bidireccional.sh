#!/usr/bin/env bash

# Verificar que Bash sea compatible
if [ -z "$BASH_VERSION" ]; then
    echo "Este script requiere Bash. Ejecuta con: bash $0" >&2
    exit 1
fi

set -uo pipefail
IFS=$'\n\t'

# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud
# Uso: 
#   Subir: ./sync_bidireccional.sh --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
#   Bajar: ./sync_bidireccional.sh --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite]

# =========================
# Configuración (ajusta a tu entorno)
# =========================
# Punto de montaje de pCloud
PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"

# Directorio local
LOCAL_DIR="${HOME}"

# Directorio de pCloud (modo normal)
PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"

# Directorio de pCloud (modo normal)
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

# Determinar el directorio donde se encuentra este script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Obtener el hostname de la máquina (usar FQDN si está disponible)
HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")

# Hostname de la maquina virtual de RTVA
HOSTNAME_RTVA="feynman.rtva.dnf"

# Archivos de configuración (buscar en el directorio del script primero, luego en el directorio actual)
LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="$HOME/sync_bidireccional.log"

# Nombre de los archivos de configuración de directorios (globales)
LISTA_POR_DEFECTO_FILE="sync_bidireccional_directorios.ini"
LISTA_ESPECIFICA_POR_DEFECTO_FILE="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"

# Nombre del archivo de exclusiones
EXCLUSIONES_FILE="sync_bidireccional_exclusiones.ini"

# Enlaces simbólicos en la subida, origen
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

# Variables de control
MODO=""
DRY_RUN=0
DELETE=0
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"
VERBOSE=0
USE_CHECKSUM=0
BW_LIMIT=""
declare -a ITEMS_ESPECIFICOS=()
declare -a EXCLUSIONES_CLI=()

# Variables para estadísticas
declare -i ELEMENTOS_PROCESADOS=0
declare -i ERRORES_SINCRONIZACION=0
declare -i ARCHIVOS_TRANSFERIDOS=0
declare -i ENLACES_CREADOS=0
declare -i ENLACES_EXISTENTES=0
declare -i ENLACES_ERRORES=0
declare -i ENLACES_DETECTADOS=0
declare -i ARCHIVOS_BORRADOS=0

# tiempo
SECONDS=0

# Configuración de locking
LOCK_FILE="${TMPDIR:-/tmp}/sync_bidireccional.lock"
LOCK_TIMEOUT=3600  # Tiempo máximo de bloqueo en segundos (1 hora)

# Temp files to cleanup
TEMP_FILES=()

# Colores
# Ejemplo de uso: echo -e "${RED}cuerpo del texto.${NC}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color (reset)

# =========================
# Sistema de logging mejorado
# =========================
log_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    registrar_log "[INFO] $msg"
}

log_warn() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    registrar_log "[WARN] $msg"
}

log_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    registrar_log "[ERROR] $msg"
}

log_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg" >&2
    registrar_log "[SUCCESS] $msg"
}

DEBUG=0
# Función de debug que se activa con DEBUG=1 o VERBOSE=1
log_debug() {
    if [ $DEBUG -eq 1 ] || [ $VERBOSE -eq 1 ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
        registrar_log "[DEBUG] $1"
    fi
}

# Función de logging optimizada con rotación automática
registrar_log() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$message" >> "$LOG_FILE"
    
    # Rotación de logs si superan 10MB (solo en modo ejecución real)
    if [ $DRY_RUN -eq 0 ] && [ -f "$LOG_FILE" ]; then
        local log_size
        if [ "$(uname)" = "Darwin" ]; then
            # macOS
            log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        else
            # Linux
            log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        fi
        
        if [ $log_size -gt 10000000 ]; then  # 10MB
            mv "$LOG_FILE" "${LOG_FILE}.old"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE" 2>/dev/null
            log_info "Log rotado automáticamente (tamaño: $((log_size/1024/1024))MB)"
        fi
    fi
}

# Manejo mejorado de errores
set -e  # Activar terminación en error
trap 'log_error "Error crítico en línea $LINENO"; exit 1' ERR

# =========================
# Utilidades
# =========================

# Normalizar rutas con realpath -m si está disponible, fallback a la ruta tal cual
normalize_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p" || printf '%s' "$p"
    else
        # realpath no disponible: intentar con readlink -f (menos portable) y si no, devolver la original
        if command -v readlink >/dev/null 2>&1; then
            readlink -m "$p" 2>/dev/null || printf '%s' "$p"
        else
            printf '%s' "$p"
        fi
    fi
}

# Función para determinar el directorio de pCloud según el modo
get_pcloud_dir() {
    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMUN"
    fi
}

# Función para verificar conectividad con pCloud
verificar_conectividad_pcloud() {
    log_debug "Verificando conectividad con pCloud..."
    
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl no disponible, omitiendo verificación de conectividad"
        return 0
    fi
    
    local max_retries=3
    local timeout=5
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if timeout ${timeout}s curl -s https://www.pcloud.com/ > /dev/null; then
            log_info "Verificación de conectividad pCloud: OK"
            return 0
        fi
        retry_count=$((retry_count + 1))
        log_warn "Intento $retry_count/$max_retries: No se pudo conectar a pCloud"
        sleep 1
    done
    
    log_error "No se pudo conectar a pCloud después de $max_retries intentos"
    log_info "Verifica tu conexión a Internet y que pCloud esté disponible"
    return 1
}

# Buscar archivos de configuración
find_config_files() {
    # Si el hostname es "${HOSTNAME_RTVA}", usar el archivo específico
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${LISTA_ESPECIFICA_POR_DEFECTO_FILE}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${LISTA_ESPECIFICA_POR_DEFECTO_FILE}"
        elif [ -f "./${LISTA_ESPECIFICA_POR_DEFECTO_FILE}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${LISTA_ESPECIFICA_POR_DEFECTO_FILE}"
        else
            log_error "No se encontró el archivo de lista específico '${LISTA_ESPECIFICA_POR_DEFECTO_FILE}'"
            log_info "Busca en:"
            log_info "  - ${SCRIPT_DIR}/"
            log_info "  - $(pwd)/"
            exit 1
        fi
    else
        # Para otros hostnames, usar el archivo por defecto
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${LISTA_POR_DEFECTO_FILE}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${LISTA_POR_DEFECTO_FILE}"
        elif [ -f "./${LISTA_POR_DEFECTO_FILE}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${LISTA_POR_DEFECTO_FILE}"
        fi
    fi
    
    # Validar que el archivo de lista existe
    if [ -n "$LISTA_SINCRONIZACION" ] && [ ! -f "$LISTA_SINCRONIZACION" ]; then
        log_error "El archivo de lista no existe: $LISTA_SINCRONIZACION"
        exit 1
    fi
    
    # Buscar archivo de exclusiones (igual para todos los hosts)
    if [ -f "${SCRIPT_DIR}/${EXCLUSIONES_FILE}" ]; then
        EXCLUSIONES="${SCRIPT_DIR}/${EXCLUSIONES_FILE}"
    elif [ -f "./${EXCLUSIONES_FILE}" ]; then
        EXCLUSIONES="./${EXCLUSIONES_FILE}"
    fi
    
    # Validar que el archivo de exclusiones existe si se especificó
    if [ -n "$EXCLUSIONES" ] && [ ! -f "$EXCLUSIONES" ]; then
        log_error "El archivo de exclusiones no existe: $EXCLUSIONES"
        exit 1
    fi
}

# Función para mostrar ayuda
mostrar_ayuda() {
    echo "Uso: $0 [OPCIONES]" >&2
    echo ""
    echo "Opciones PRINCIPALES (obligatorio una de ellas):"
    echo "  --subir            Sincroniza desde el directorio local a pCloud (${LOCAL_DIR} → pCloud)"
    echo "  --bajar            Sincroniza desde pCloud al directorio local (pCloud → ${LOCAL_DIR})"
    echo ""
    echo "Opciones SECUNDARIAS (opcionales):"
    echo "  --delete           Elimina en destino los archivos que no existan en origen (delete-delay)"
    echo "  --dry-run          Simula la operación sin hacer cambios reales"
    echo "  --item ELEMENTO    Sincroniza solo el elemento especificado (archivo o directorio)"
    echo "  --yes              No pregunta confirmación, ejecuta directamente"
    echo "  --backup-dir       Usa el directorio de backup de solo lectura (pCloud Backup) en lugar de Backup_Comun"
    echo "  --exclude PATRON   Excluye archivos que coincidan con el patrón (puede usarse múltiples veces)"
    echo "  --overwrite        Sobrescribe todos los archivos en destino (no usa --update)"
    echo "  --checksum         Fuerza comparación con checksum (más lento)"  
    echo "  --bwlimit KB/s     Limita la velocidad de transferencia (ej: 1000 para 1MB/s)"
    echo "  --timeout MINUTOS  Límite de tiempo por operación (default: 30)"
    echo "  --force-unlock     Forzando eliminación de lock"      
    echo "  --verbose          Habilita modo verboso para debugging"
    echo "  --test             Ejecutar tests unitarios"
    echo "  --help             Muestra esta ayuda"
    echo ""
    echo "Archivos de configuración:" >&2
    echo "  - Directorio del script: ${SCRIPT_DIR}/"
    echo "  - Directorio actual: $(pwd)/"
    
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        echo "  - Busca: ${LISTA_ESPECIFICA_POR_DEFECTO_FILE} (específico para este host)"
    else
        echo "  - Busca: ${LISTA_POR_DEFECTO_FILE} (por defecto)"
    fi
    
    echo "  - Busca: ${EXCLUSIONES_FILE}"
    echo ""
    echo "Hostname detectado: ${HOSTNAME}" >&2
    echo ""
    echo "Ejemplos:"
    echo "  sync_bidireccional.sh --subir"
    echo "  sync_bidireccional.sh --bajar --dry-run"
    echo "  sync_bidireccional.sh --subir --delete --yes"
    echo "  sync_bidireccional.sh --subir --item documentos/"
    echo "  sync_bidireccional.sh --bajar --item configuracion.ini --item .local/bin --dry-run"
    echo "  sync_bidireccional.sh --bajar --backup-dir --item documentos/ --yes"
    echo "  sync_bidireccional.sh --subir --exclude '*.tmp' --exclude 'temp/'"
    echo "  sync_bidireccional.sh --subir --overwrite     # Sobrescribe todos los archivos"
    echo "  sync_bidireccional.sh --subir --bwlimit 1000  # Sincronizar subiendo con límite de 1MB/s" 
    echo "  sync_bidireccional.sh --subir --verbose       # Sincronizar con output verboso"
    echo "  sync_bidireccional.sh --bajar --item Documentos/ --timeout 10  # Timeout corto de 10 minutos para una operación rápida"
    echo "  sync_bidireccional.sh --force-unlock   # Forzar desbloqueo si hay un lock obsoleto"
    echo "  sync_bidireccional.sh --test           # Ejecutar tests unitarios"
}

# Función para procesar argumentos de línea de comandos
procesar_argumentos() {
	# Procesar argumentos
	if [ $# -eq 0 ] || [[ "$*" =~ --help ]]; then
		log_error "Debes especificar al menos --subir o --bajar"
		mostrar_ayuda
		exit 1
	fi

	log_debug "Argumentos recibidos: $*"

	# Verificación de argumentos duplicados (solo para opciones)
	declare -A seen_opts
	for ((i=1; i<=$#; i++)); do
        arg="${!i}"
        if [[ "$arg" == --* ]] && [[ "$arg" != "--item" ]] && [[ "$arg" != "--exclude" ]]; then
            if [[ -v seen_opts["$arg"] ]]; then
                log_error "Opción duplicada: $arg"
                exit 1
            fi
            seen_opts["$arg"]=1
        elif [[ "$arg" == --item ]] || [[ "$arg" == --exclude ]]; then
            ((i++))  # Saltar el siguiente argumento (valor de --item o --exclude)
        fi
 	done

    # Procesar cada argumento
    while [[ $# -gt 0 ]]; do
        case $1 in
            --subir)
                [ -n "$MODO" ] && { log_error "No puedes usar --subir y --bajar simultáneamente"; exit 1; }
                MODO="subir"; shift;;
            --bajar)
                [ -n "$MODO" ] && { log_error "No puedes usar --subir y --bajar simultáneamente"; exit 1; }
                MODO="bajar"; shift;;
            --delete)
                DELETE=1; shift;;
            --dry-run)
                DRY_RUN=1; shift;;
            --item)
                [ -z "$2" ] && { log_error "--item requiere un argumento"; exit 1; }
                ITEMS_ESPECIFICOS+=("$2"); shift 2;;
            --exclude)
                [ -z "$2" ] && { log_error "--exclude requiere un patrón"; exit 1; }
                EXCLUSIONES_CLI+=("$2"); shift 2;;
            --yes)
                YES=1; shift;;
            --backup-dir)
                BACKUP_DIR_MODE="readonly"; shift;;
            --overwrite)
                OVERWRITE=1; shift;;
            --checksum)
                USE_CHECKSUM=1; shift;;
            --bwlimit)
                [ -z "$2" ] && { log_error "--bwlimit requiere un valor (KB/s)"; exit 1; }
                BW_LIMIT="$2"; shift 2;;
            --timeout)
                [ -z "$2" ] && { log_error "--timeout requiere minutos"; exit 1; }
                TIMEOUT_MINUTES="$2"; shift 2;;
            --force-unlock)
                log_warn "Forzando eliminación de lock: $LOCK_FILE"
                rm -f "$LOCK_FILE"
                exit 0;;
            --verbose) 
                VERBOSE=1; shift;;
            --test)
                run_tests; exit $?;;
            -h|--help)
                mostrar_ayuda; exit 0;;
            *)
                log_error "Opción desconocida: $1"; mostrar_ayuda; exit 1;;
        esac
    done
}

# Función para verificar si pCloud está montado
verificar_pcloud_montado() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(normalize_path "$(get_pcloud_dir)")

    # Verificar si el punto de montaje de pCloud existe
    log_debug "Verificando montaje de pCloud en: $PCLOUD_MOUNT_POINT"

    if [[ ! -d "$PCLOUD_MOUNT_POINT" ]]; then
        log_error "El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT"
        log_info "Asegúrate de que pCloud Drive esté instalado y ejecutándose."
        return 1
    fi
    
    # Verificación más robusta: comprobar si pCloud está realmente montado
    # 1. Verificar si el directorio está vacío (puede indicar que no está montado)
    log_debug "Verificando si el directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT"
    if [ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]; then
        log_error "El directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT"
        log_info "Esto sugiere que pCloud Drive no está montado correctamente."
        exit 1
    fi

    # 2. Verificar usando el comando mount
    if command -v findmnt &>/dev/null; then
        log_debug "Verificando montaje con findmnt..."
        if ! findmnt -rno TARGET "$PCLOUD_MOUNT_POINT" &>/dev/null; then
            log_error "pCloud no aparece montado en $PCLOUD_MOUNT_POINT"
            exit 1
        fi
    elif command -v mountpoint &>/dev/null; then
        log_debug "Verificando montaje con mountpoint..."
        if ! mountpoint -q "$PCLOUD_MOUNT_POINT"; then
            log_error "pCloud no aparece montado en $PCLOUD_MOUNT_POINT"
            exit 1
        fi
    else
        log_debug "Verificando montaje con /proc/mounts..."
        if ! grep -q "pcloud" /proc/mounts 2>/dev/null; then
            log_error "pCloud no aparece en /proc/mounts"
            exit 1
        fi
    fi
    
    # Verificación adicional con df (más genérica) 
    log_debug "Verificando montaje con df..."

    if ! df -P "$PCLOUD_MOUNT_POINT" &>/dev/null; then
        log_error "pCloud no está montado correctamente en $PCLOUD_MOUNT_POINT"
        exit 1
    fi
    
    # Verificar si el directorio específico de pCloud existe
    if [ ! -d "$PCLOUD_DIR" ]; then
        log_debug "El directorio de pCloud no existe: $PCLOUD_DIR"
        log_error "El directorio de pCloud no existe: $PCLOUD_DIR"
        log_info "Asegúrate de que:"
        log_info "1. pCloud Drive esté ejecutándose"
        log_info "2. Tu cuenta de pCloud esté sincronizada"
        log_info "3. El directorio exista en tu pCloud"
        exit 1
    fi
    
    # Verificación adicional: intentar escribir en el directorio (solo si no es dry-run y no es modo backup-dir)
    if [ $DRY_RUN -eq 0 ] && [ "$BACKUP_DIR_MODE" = "comun" ]; then
        log_debug "Verificando permisos de escritura en: $PCLOUD_DIR"
        local test_file="${PCLOUD_DIR}/.test_write_$$"
        if ! touch "$test_file" 2>/dev/null; then
            log_error "No se puede escribir en: $PCLOUD_DIR"
            exit 1
        fi
        rm -f "$test_file"
    fi

    log_debug "Verificación de pCloud completada con éxito."
    log_info "Verificación de pCloud: OK - El directorio está montado y accesible"
}

# Función para mostrar el banner informativo
mostrar_banner() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

    log_debug "Mostrando banner informativo."

    echo "=========================================="
    if [ "$MODO" = "subir" ]; then
        echo "MODO: SUBIR (Local → pCloud)"
        echo "ORIGEN: ${LOCAL_DIR}"
        echo "DESTINO: ${PCLOUD_DIR}"
    else
        echo "MODO: BAJAR (pCloud → Local)"
        echo "ORIGEN: ${PCLOUD_DIR}"
        echo "DESTINO: ${LOCAL_DIR}"
    fi

    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "DIRECTORIO: Backup de solo lectura (pCloud Backup)"
    else
        echo "DIRECTORIO: Backup común (Backup_Comun)"
    fi
    
    if [ $DRY_RUN -eq 1 ]; then
        echo -e "ESTADO: ${YELLOW}MODO SIMULACIÓN${NC} (no se realizarán cambios)"
    fi
    
    if [ $DELETE -eq 1 ]; then
        echo -e "BORRADO: ${GREEN}ACTIVADO${NC} (se eliminarán archivos obsoletos)"
    fi
    
    if [ $YES -eq 1 ]; then
        echo "CONFIRMACIÓN: Automática (sin preguntar)"
    fi
    
    if [ $OVERWRITE -eq 1 ]; then
        echo -e "SOBRESCRITURA: ${GREEN}ACTIVADA${NC}"
    else
        echo "MODO: SEGURO (--update activado)"
    fi

	if [ ${#ITEMS_ESPECIFICOS[@]} -gt 0 ] && [ -n "${ITEMS_ESPECIFICOS[0]}" ]; then
		echo "ELEMENTOS ESPECÍFICOS: ${ITEMS_ESPECIFICOS[*]}"
	else
		echo "LISTA: ${LISTA_SINCRONIZACION:-No encontrada}"
	fi

    echo "EXCLUSIONES: ${EXCLUSIONES:-No encontradas}"
    
    # Exclusiones linea comandos EXCLUSIONES_CLI
    if [ ${#EXCLUSIONES_CLI[@]} -gt 0 ]; then
        echo "EXCLUSIONES CLI (${#EXCLUSIONES_CLI[@]} patrones):"
        for i in "${!EXCLUSIONES_CLI[@]}"; do
            echo "  $((i+1)). ${EXCLUSIONES_CLI[$i]}"
        done
    fi
    echo "=========================================="
}

# Función para confirmar la ejecución
confirmar_ejecucion() {
    if [ $YES -eq 1 ]; then
        log_info "Confirmación automática (--yes): se procede con la sincronización"
        return
    fi
    
    echo ""
    if [ -t 0 ]; then
        read -r -p "¿Desea continuar con la sincronización? [s/N]: " respuesta
        if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
            log_info "Operación cancelada por el usuario."
            exit 0
        fi
        echo ""
    else
        log_error "No hay entrada interactiva disponible (usa --yes)"
        exit 1
    fi
    echo ""
}

# Función para verificar y crear archivo de log
inicializar_log() {
    # Truncar log si supera 10MB (compatible con macOS y Linux)
    log_debug "Inicializando archivo de log: $LOG_FILE"

    if [ -f "$LOG_FILE" ]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS
            LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        else
            # Linux
            LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        fi
        
        if [ $LOG_SIZE -gt 5242880 ]; then
            : > "$LOG_FILE"
        fi
    fi

    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE" 2>/dev/null
    {
        echo "=========================================="
        echo "Sincronización iniciada: $(date)"
        echo "Modo: $MODO"
        echo "Delete: $DELETE"
        echo "Dry-run: $DRY_RUN"
        echo "Backup-dir: $BACKUP_DIR_MODE"
        echo "Overwrite: $OVERWRITE"
        echo "Checksum: $USE_CHECKSUM"
        [ ${#ITEMS_ESPECIFICOS[@]} -gt 0 ] && echo "Items específicos: ${ITEMS_ESPECIFICOS[*]}"
        echo "Lista sincronización: ${LISTA_SINCRONIZACION:-No encontrada}"
        echo "Exclusiones: ${EXCLUSIONES:-No encontradas}"
    } >> "$LOG_FILE"
}

# Función para verificar dependencias
verificar_dependencias() {
    log_debug "Verificando dependencias..."
    if ! command -v rsync >/dev/null 2>&1; then
        log_error "rsync no está instalado. Instálalo con:"
        log_info "sudo apt install rsync  # Debian/Ubuntu"
        log_info "sudo dnf install rsync  # RedHat/CentOS"
        exit 1
    fi
}

# Función para verificar la existencia de todos los elementos en el archivo de configuración
verificar_elementos_configuracion() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)
    local errores=0

    log_info "Verificando existencia de todos los elementos en la configuración..."
    
    if [ ${#ITEMS_ESPECIFICOS[@]} -gt 0 ]; then
        # Verificar items específicos de línea de comandos
        for elemento in "${ITEMS_ESPECIFICOS[@]}"; do
            resolver_item_relativo "$elemento"
            if [ -n "$REL_ITEM" ]; then
                if [ "$MODO" = "subir" ]; then
                    if [ ! -e "${LOCAL_DIR}/${REL_ITEM}" ]; then
                        log_error "El elemento específico '${REL_ITEM}' no existe en el directorio local: ${LOCAL_DIR}/${REL_ITEM}"
                        errores=1
                    fi
                else
                    if [ ! -e "${PCLOUD_DIR}/${REL_ITEM}" ]; then
                        log_error "El elemento específico '${REL_ITEM}' no existe en pCloud: ${PCLOUD_DIR}/${REL_ITEM}"
                        errores=1
                    fi
                fi
            fi
        done
    else
        # Verificar elementos del archivo de configuración
        while IFS= read -r linea || [ -n "$linea" ]; do
            [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue
            [[ -z "${linea// }" ]] && continue
            
            # Validación de seguridad adicional
            if [[ "$linea" =~ (^|/)\.\.(/|$) ]] || [[ "$linea" =~ ^\.\./ ]] || [[ "$linea" =~ /\.\.$ ]]; then
                log_error "Path traversal detectado en el archivo de configuración: $linea"
                errores=1
                continue
            fi
            
            if [ "$MODO" = "subir" ]; then
                if [ ! -e "${LOCAL_DIR}/${linea}" ]; then
                    log_error "El elemento '$linea' no existe en el directorio local: ${LOCAL_DIR}/${linea}"
                    errores=1
                fi
            else
                if [ ! -e "${PCLOUD_DIR}/${linea}" ]; then
                    log_error "El elemento '$linea' no existe en pCloud: ${PCLOUD_DIR}/${linea}"
                    errores=1
                fi
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    if [ $errores -eq 1 ]; then
        log_error "Se encontraron errores en la configuración. Corrige los elementos antes de continuar."
        return 1
    fi
    
    log_info "✓ Todos los elementos verificados existen"
    return 0
}

# Función para verificar archivos de configuración
verificar_archivos_configuracion() {
    log_debug "Verificando archivos de configuración..."
    
    # Verificar que el archivo de lista existe y es legible
    if [ ${#ITEMS_ESPECIFICOS[@]} -eq 0 ] && { [ -z "$LISTA_SINCRONIZACION" ] || [ ! -f "$LISTA_SINCRONIZACION" ]; }; then
        log_error "No se encontró el archivo de lista 'LISTA_POR_DEFECTO_FILE'"
        log_info "Busca en:"
        log_info "  - ${SCRIPT_DIR}/"
        log_info "  - $(pwd)/"
        log_info "O crea un archivo con la lista de rutas a sincronizar o usa --item"
        exit 1
    fi
    
    # Verificar permisos de lectura del archivo de lista
    if [ -n "$LISTA_SINCRONIZACION" ] && [ ! -r "$LISTA_SINCRONIZACION" ]; then
        log_error "Sin permisos de lectura para el archivo de lista: $LISTA_SINCRONIZACION"
        exit 1
    fi
    
    # Verificar que el archivo de lista no esté vacío
    if [ -n "$LISTA_SINCRONIZACION" ] && [ ! -s "$LISTA_SINCRONIZACION" ]; then
        log_error "El archivo de lista está vacío: $LISTA_SINCRONIZACION"
        exit 1
    fi
    
    # Verificar archivo de exclusiones si se especificó
    if [ -n "$EXCLUSIONES" ] && [ ! -f "$EXCLUSIONES" ]; then
        log_error "El archivo de exclusiones no existe: $EXCLUSIONES"
        exit 1
    fi
    
    # Verificar permisos de lectura del archivo de exclusiones
    if [ -n "$EXCLUSIONES" ] && [ ! -r "$EXCLUSIONES" ]; then
        log_error "Sin permisos de lectura para el archivo de exclusiones: $EXCLUSIONES"
        exit 1
    fi
}

# Construye opciones de rsync (en array para evitar problemas de espacios)
declare -a RSYNC_OPTS
construir_opciones_rsync() {
    log_debug "Construyendo opciones de rsync..."

    RSYNC_OPTS=(
        --recursive 
        --verbose 
        --times 
        --progress 
        --whole-file 
        --no-links 
        --itemize-changes
    )
    
    [ $OVERWRITE -eq 0 ] && RSYNC_OPTS+=(--update)
    [ $DRY_RUN -eq 1 ] && RSYNC_OPTS+=(--dry-run)
    [ $DELETE -eq 1 ] && RSYNC_OPTS+=(--delete-delay)
    [ $USE_CHECKSUM -eq 1 ] && RSYNC_OPTS+=(--checksum)

    # Límite de ancho de banda (si está configurado)
    log_debug "BW_LIMIT: ${BW_LIMIT:-no establecido}"
    [ -n "$BW_LIMIT" ] && RSYNC_OPTS+=(--bwlimit="$BW_LIMIT")
    
    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        RSYNC_OPTS+=(--exclude-from="$EXCLUSIONES")
    fi
        
    # Añadir exclusiones de línea de comandos
    if [ ${#EXCLUSIONES_CLI[@]} -gt 0 ]; then
        for patron in "${EXCLUSIONES_CLI[@]}"; do
            RSYNC_OPTS+=(--exclude="$patron")
        done
        log_info "Exclusiones por CLI aplicadas: ${#EXCLUSIONES_CLI[@]} patrones"
    fi
    
    log_debug "Opciones finales de rsync: ${RSYNC_OPTS[*]}"
}

# Función para mostrar estadísticas completas
mostrar_estadísticas() {
    local tiempo_total=$SECONDS
    log_debug "Generando estadísticas. Tiempo total: $tiempo_total segundos."
    local horas=$((tiempo_total / 3600))
    local minutos=$(( (tiempo_total % 3600) / 60 ))
    local segundos=$((tiempo_total % 60))
    
    echo ""
    echo "=========================================="
    echo "RESUMEN DE SINCRONIZACIÓN"
    echo "=========================================="
    echo "Elementos procesados: $ELEMENTOS_PROCESADOS"
    echo "Archivos transferidos: $ARCHIVOS_TRANSFERIDOS" 
    [ $DELETE -eq 1 ] && echo "Archivos borrados en destino: $ARCHIVOS_BORRADOS"
    [ ${#EXCLUSIONES_CLI[@]} -gt 0 ] && echo "Exclusiones CLI aplicadas: ${#EXCLUSIONES_CLI[@]} patrones"
    echo "Enlaces manejados: $((ENLACES_CREADOS + ENLACES_EXISTENTES))"
    echo "  - Enlaces detectados/guardados: $ENLACES_DETECTADOS" 
    echo "  - Enlaces creados: $ENLACES_CREADOS"
    echo "  - Enlaces existentes: $ENLACES_EXISTENTES"
    echo "  - Enlaces con errores: $ENLACES_ERRORES"
    echo "Errores de sincronización: $ERRORES_SINCRONIZACION"
    
    if [ $tiempo_total -ge 3600 ]; then
        echo "Tiempo total: ${horas}h ${minutos}m ${segundos}s"
    elif [ $tiempo_total -ge 60 ]; then
        echo "Tiempo total: ${minutos}m ${segundos}s"
    else
        echo "Tiempo total: ${segundos}s"
    fi
    
    echo "Velocidad promedio: $((ARCHIVOS_TRANSFERIDOS / (tiempo_total > 0 ? tiempo_total : 1))) archivos/segundo"
    echo "Modo: $([ $DRY_RUN -eq 1 ] && echo 'SIMULACIÓN' || echo 'EJECUCIÓN REAL')"
    echo "=========================================="
}

# Función para verificar espacio disponible en disco
verificar_espacio_disco() {
    local needed_mb=${1:-100}  # MB mínimos por defecto: 100MB
    local available_mb
    local mount_point
    local tipo_operacion
    
    log_debug "Verificando espacio en disco. Necesarios: $needed_mb MB."

    # Determinar el punto de montaje a verificar según el modo
    if [ "$MODO" = "subir" ]; then
        mount_point="$PCLOUD_MOUNT_POINT"
        tipo_operacion="SUBIDA a pCloud"
    else
        mount_point="$LOCAL_DIR"
        tipo_operacion="BAJADA desde pCloud"
    fi

    # Verificar que el punto de montaje existe
    if [ ! -d "$mount_point" ]; then
        log_debug "El punto de montaje $mount_point no existe, omitiendo verificación de espacio."
        log_warn "El punto de montaje $mount_point no existe, omitiendo verificación de espacio"
        return 0
    fi

    # Obtener espacio disponible de forma portable
    if [ "$(uname)" = "Darwin" ]; then
        # macOS
        available_mb=$(df -m "$mount_point" | awk 'NR==2 {print $4}')
    else
        # Linux
        available_mb=$(df -m --output=avail "$mount_point" | awk 'NR==2 {print $1}')
    fi

    # Validar que se obtuvo un valor numérico
    if ! [[ "$available_mb" =~ ^[0-9]+$ ]]; then
        log_debug "No se pudo obtener el espacio disponible en $mount_point."
        log_warn "No se pudo determinar el espacio disponible en $mount_point, omitiendo verificación"
        return 0  # Continuar a pesar de la advertencia
    fi

    if [ "$available_mb" -lt "$needed_mb" ]; then
        log_error "Espacio insuficiente para $tipo_operacion en $mount_point" 
        log_error "Disponible: ${available_mb}MB, Necesario: ${needed_mb}MB"
        return 1
    fi

    log_debug "Espacio suficiente disponible: ${available_mb}MB."
    log_info "Espacio en disco verificado para $tipo_operacion. Disponible: ${available_mb}MB"
    return 0
}

# Función para enviar notificaciones del sistema
enviar_notificacion() {
    local titulo="$1"
    local mensaje="$2"
    local tipo="${3:-info}"  # info, error, warning
    
    # Para sistemas Linux con notify-send
    if command -v notify-send >/dev/null 2>&1; then       
        # Determinar la urgencia según el tipo (nunca usar "low")
        local urgencia="normal"  # Valor por defecto cambiado de "low" a "normal"
        local icono="dialog-information"
        case "$tipo" in
            error) 
                urgencia="critical"
                icono="dialog-error"
                ;;
            warning) 
                urgencia="normal" 
                icono="dialog-warning"
                ;;
            # info ya usa "normal" por defecto
        esac
        
        notify-send --urgency="$urgencia" --icon="$icono" "$titulo" "$mensaje"
    
    # Para sistemas macOS
    elif command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$mensaje\" with title \"$titulo\""
    
    # Fallback para terminal
    else
        echo -e "\n🔔 $titulo: $mensaje"
    fi
}

# Función para notificar finalización
notificar_finalizacion() {
    local exit_code=$1
    
    # Pequeña pausa para asegurar que todas las operaciones previas han terminado
    sleep 0.5
    
    if [ $exit_code -eq 0 ]; then
        enviar_notificacion "Sincronización Completada" \
            "Sincronización finalizada con éxito\n• Elementos: $ELEMENTOS_PROCESADOS\n• Transferidos: $ARCHIVOS_TRANSFERIDOS\n• Tiempo: ${SECONDS}s" \
            "info"
    else
        enviar_notificacion "Sincronización con Errores" \
            "Sincronización finalizada con errores\n• Errores: $ERRORES_SINCRONIZACION\n• Verifique el log: $LOG_FILE" \
            "error"
    fi
}

# Función para obtener información del proceso dueño del lock
obtener_info_proceso_lock() {
    local pid=$1
    if ps -p $pid > /dev/null 2>&1; then
        echo "Dueño del lock: PID $pid, Comando: $(ps -p $pid -o comm=), Iniciado: $(ps -p $pid -o lstart=)"
    else
        echo "Dueño del lock: PID $pid (proceso ya terminado)"
    fi
}

# Función para establecer el lock
establecer_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log_debug "Archivo de lock encontrado: $LOCK_FILE"
        local lock_pid=$(head -n 1 "$LOCK_FILE" 2>/dev/null)
        local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)
        local current_time=$(date +%s)
        local lock_age=$((current_time - lock_time))
        
        if [ $lock_age -gt $LOCK_TIMEOUT ]; then
            log_warn "Eliminando lock obsoleto (edad: ${lock_age}s > timeout: ${LOCK_TIMEOUT}s)"
            rm -f "$LOCK_FILE"
        elif ps -p "$lock_pid" > /dev/null 2>&1; then
            log_error "Ya hay una ejecución en progreso (PID: $lock_pid)"
            log_error "$(obtener_info_proceso_lock $lock_pid)"
            return 1
        else
            log_warn "Eliminando lock obsoleto del proceso $lock_pid"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    if ! echo $$ > "$LOCK_FILE"; then
        log_error "No se pudo crear el archivo de lock: $LOCK_FILE"
        return 1
    fi
    
    # Añadir información adicional al lock file
    {
        echo "PID: $$"
        echo "Fecha: $(date)"
        echo "Modo: $MODO"
        echo "Usuario: $(whoami)"
        echo "Hostname: $(hostname)"
    } >> "$LOCK_FILE"
    
    log_debug "Lock establecido para PID: $$"
    log_info "Lock establecido: $LOCK_FILE"
    return 0
}

# Función para eliminar el lock
eliminar_lock() {
    if [ -f "$LOCK_FILE" ] && [[ "$(head -n 1 "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        log_debug "Eliminando lock para PID: $$" 
        rm -f "$LOCK_FILE"
        log_info "Lock eliminado"
    fi
}

# Función específica para eliminar el lock
eliminar_lock_final() {
    if [ -f "$LOCK_FILE" ] && [ "$(head -n 1 "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        log_debug "Eliminando lock final para PID: $$"
        rm -f "$LOCK_FILE"
        log_info "Lock eliminado"
    fi
}

# =========================
# Validación y utilidades rsync
# =========================
validate_rsync_opts() {
    for opt in "${RSYNC_OPTS[@]:-}"; do
        log_debug "Validando opción de rsync: $opt"
        # Si por alguna razón aparece la cadena 'rsync' en una opción, abortar
       if echo "$opt" | grep -qi 'rsync'; then
            log_error "RSYNC_OPTS contiene un elemento sospechoso con 'rsync': $opt"
            log_info "Contenido actual de RSYNC_OPTS:"
            declare -p RSYNC_OPTS
            return 1
        fi
    done
    return 0
}

print_rsync_command() {
    log_debug "Imprimiendo comando rsync..."
    local origen="$1" destino="$2"
    printf "Comando: "
    printf "%q " rsync
    for el in "${RSYNC_OPTS[@]}"; do
        printf "%q " "$el"
    done
    printf "%q %q\n" "$origen" "$destino"
}

# =========================
# ENLACES SIMBÓLICOS
# =========================
# Función para registrar un enlace individual
registrar_enlace() {
    local enlace="$1"
    local archivo_enlaces="$2"

    log_debug "Procesando enlace simbólico: $enlace"
    # Solo enlaces simbólicos
    [ -L "$enlace" ] || return

    # Columna 1: ruta del ENLACE relativa a $HOME
    local ruta_relativa="$enlace"
    if [[ "$ruta_relativa" == "$LOCAL_DIR/"* ]]; then
        ruta_relativa="${ruta_relativa#${LOCAL_DIR}/}"
    else
        ruta_relativa="${ruta_relativa#/}"
    fi

    # Columna 2: destino tal cual fue creado el enlace
    local destino
    destino="$(readlink "$enlace" 2>/dev/null || true)"

    # Validaciones: no escribir líneas incompletas
    if [ -z "$ruta_relativa" ] || [ -z "$destino" ]; then
        log_debug "Enlace no válido o vacío: $enlace"
        log_warn "Enlace no válido u origen/destino vacío: $enlace"
        return
    fi

    # Normalización del destino
    if [[ "$destino" == "$HOME"* ]]; then
        destino="/home/\$USERNAME${destino#$HOME}"
    elif [[ "$destino" == /home/* ]]; then
        local _tmp="${destino#/home/}"
        if [[ "$_tmp" == */* ]]; then
            local _rest="${_tmp#*/}"
            destino="/home/\$USERNAME/${_rest}"
        else
            destino="/home/\$USERNAME"
        fi
    fi

    printf "%s\t%s\n" "$ruta_relativa" "$destino" >> "$archivo_enlaces"
    log_debug "Registrado enlace simbólico: $ruta_relativa -> $destino"
    log_info "Registrado enlace: $ruta_relativa -> $destino"
    ENLACES_DETECTADOS=$((ENLACES_DETECTADOS + 1))
}

# Función para buscar enlaces en un directorio
buscar_enlaces_en_directorio() {
    local dir="$1"
    local archivo_enlaces="$2"
    
    [ -d "$dir" ] || return
    log_debug "Buscando enlaces en directorio: $dir"
    
    while IFS= read -r -d '' enlace; do
        registrar_enlace "$enlace" "$archivo_enlaces"
    done < <(find "$dir" -type l -print0 2>/dev/null)
}

# Función principal para generar archivo de enlaces
generar_archivo_enlaces() {
    local archivo_enlaces="$1"
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

    log_debug "Generando archivo de enlaces: $archivo_enlaces"
    log_info "Generando archivo de enlaces simbólicos..."
    
    : > "$archivo_enlaces" || {
        log_error "No se pudo crear el archivo temporal de enlaces"
        return 1
    }

    if [ ${#ITEMS_ESPECIFICOS[@]} -gt 0 ] && [ -n "${ITEMS_ESPECIFICOS[0]}" ]; then
        for elemento in "${ITEMS_ESPECIFICOS[@]}"; do
            local ruta_completa="${LOCAL_DIR}/${elemento}"
            log_debug "Buscando enlaces para elemento específico: $ruta_completa"
            
            if [ -L "$ruta_completa" ]; then
                registrar_enlace "$ruta_completa" "$archivo_enlaces"
            elif [ -d "$ruta_completa" ]; then
                buscar_enlaces_en_directorio "$ruta_completa" "$archivo_enlaces"
            fi
        done
    else
        while IFS= read -r elemento || [[ -n "$elemento" ]]; do
            [[ -n "$elemento" && ! "$elemento" =~ ^[[:space:]]*# ]] || continue
            
            # Validación de seguridad adicional
            if [[ "$elemento" == *".."* ]]; then
                log_error "Elemento contiene '..' - posible path traversal: $elemento"
                continue
            fi
            
            local ruta_completa="${LOCAL_DIR}/${elemento}"
            if [ -L "$ruta_completa" ]; then
                registrar_enlace "$ruta_completa" "$archivo_enlaces"
            elif [ -d "$ruta_completa" ]; then
                buscar_enlaces_en_directorio "$ruta_completa" "$archivo_enlaces"
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    if [ -s "$archivo_enlaces" ]; then
        log_debug "Sincronizando archivo de enlaces a pCloud..."
        log_info "Sincronizando archivo de enlaces..."
        construir_opciones_rsync
        validate_rsync_opts || { log_error "Abortando: RSYNC_OPTS inválido"; return 1; }
        print_rsync_command "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"
        if rsync "${RSYNC_OPTS[@]}" "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"; then
            log_info "Enlaces detectados/guardados en meta: $ENLACES_DETECTADOS"
            log_success "Archivo de enlaces sincronizado"
        else
            log_error "Error sincronizando archivo de enlaces"
            return 1
        fi
    else
        log_debug "No se encontraron enlaces simbólicos."
        log_info "No se encontraron enlaces simbólicos para registrar"
    fi

    rm -f "$archivo_enlaces"
}

# Función para recrear enlaces simbólicos 
procesar_linea_enlace() {
    local ruta_enlace="$1"
    local destino="$2"
    local exit_code=0

    local ruta_completa="${LOCAL_DIR}/${ruta_enlace}"
    local dir_padre
    dir_padre=$(dirname "$ruta_completa")

    log_debug "Procesando enlace: $ruta_enlace -> $destino"
    
    if [[ ! -d "$dir_padre" ]] && [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$dir_padre"
    fi

    # Normalizar destino y validar
    local destino_para_ln="$destino"
    [[ "$destino_para_ln" == \$HOME* ]] && destino_para_ln="${HOME}${destino_para_ln#\$HOME}"
    destino_para_ln="${destino_para_ln//\$USERNAME/$USER}"
    destino_para_ln=$(normalize_path "$destino_para_ln")

    # Validar que esté dentro de $HOME
    if [[ "$destino_para_ln" != "$HOME"* ]]; then
        log_debug "Destino de enlace fuera de HOME: $destino_para_ln"
        log_warn "Destino de enlace fuera de \$HOME, se omite: $ruta_enlace -> $destino_para_ln" 
        return 0
    fi

    # Si ya existe y apunta a lo mismo
    if [ -L "$ruta_completa" ]; then
        local destino_actual
        destino_actual=$(readlink "$ruta_completa" 2>/dev/null || true)

        if [ "$destino_actual" = "$destino_para_ln" ]; then
            log_debug "Enlace ya existe y es correcto: $ruta_enlace"
            log_info "Enlace ya existe y es correcto: $ruta_enlace -> $destino_para_ln"
            ENLACES_EXISTENTES=$((ENLACES_EXISTENTES + 1))
            return 0
        fi
        rm -f "$ruta_completa"
    fi

    # Crear el enlace
    if [ $DRY_RUN -eq 1 ]; then
        log_info "SIMULACIÓN: ln -sfn '$destino_para_ln' '$ruta_completa'"
        log_debug "SIMULACIÓN: Enlace a crear: $ruta_completa -> $destino_para_ln"
        ENLACES_CREADOS=$((ENLACES_CREADOS + 1))
    else
        if ln -sfn "$destino_para_ln" "$ruta_completa" 2>/dev/null; then
            log_info "Creado enlace: $ruta_enlace -> $destino_para_ln"
            log_debug "Enlace creado: $ruta_completa -> $destino_para_ln"
            ENLACES_CREADOS=$((ENLACES_CREADOS + 1))
        else
            log_error "Error creando enlace: $ruta_enlace -> $destino_para_ln"
            ENLACES_ERRORES=$((ENLACES_ERRORES + 1))
            exit_code=1
        fi
    fi

    return $exit_code
}

recrear_enlaces_desde_archivo() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)
    local archivo_enlaces_origen="${PCLOUD_DIR}/${SYMLINKS_FILE}"
    local archivo_enlaces_local="${LOCAL_DIR}/${SYMLINKS_FILE}"
    local exit_code=0

    log_debug "Buscando archivo de enlaces en: $archivo_enlaces_origen"
    log_info "Buscando archivo de enlaces..."

    if [ -f "$archivo_enlaces_origen" ]; then
        cp -f "$archivo_enlaces_origen" "$archivo_enlaces_local"
        log_info "Archivo de enlaces copiado localmente"
    elif [ -f "$archivo_enlaces_local" ]; then
        log_info "Usando archivo de enlaces local existente"
    else
        log_debug "No se encontró archivo de enlaces."
        log_info "No se encontró archivo de enlaces, omitiendo recreación"
        return 0
    fi

    log_info "Recreando enlaces simbólicos..."

    while IFS=$'\t' read -r ruta_enlace destino || [ -n "$ruta_enlace" ] || [ -n "$destino" ]; do
        if [ -z "$ruta_enlace" ] || [ -z "$destino" ]; then
            log_warn "Línea inválida en archivo de enlaces (se omite)"
            log_debug "Línea inválida en archivo de enlaces: ruta_enlace=$ruta_enlace, destino=$destino"
            continue
        fi

        if ! procesar_linea_enlace "$ruta_enlace" "$destino"; then
            exit_code=1
        fi
    done < "$archivo_enlaces_local"

    log_info "Enlaces recreados: $ENLACES_CREADOS, Errores: $ENLACES_ERRORES"
    [ $DRY_RUN -eq 0 ] && rm -f "$archivo_enlaces_local"
    
    return $exit_code
}


# =========================
# SINCRONIZACIÓN
# =========================
resolver_item_relativo() {
    local item="$1"
    
    if [[ -z "$item" ]]; then
        REL_ITEM=""
        return
    fi
    
	# Detectar varios patrones de path traversal
	if [[ "$item" =~ (^|/)\.\.(/|$) ]] || [[ "$item" =~ ^\.\./ ]] || [[ "$item" =~ /\.\.$ ]]; then
		log_error "Path traversal detectado: $item"
		exit 1
	fi
    
    if [[ "$item" = /* ]]; then
        if [[ "$item" == "$LOCAL_DIR/"* ]]; then
            REL_ITEM="${item#${LOCAL_DIR}/}"
        else
            log_error "--item apunta fuera de \$HOME: $item"
            exit 1
        fi
    else
        REL_ITEM="$item"
    fi
    
    # Validación de seguridad: evitar path traversal
    # Normalizar y validar ruta relativa
	# Si REL_ITEM es absoluta, no tocar; si es relativa, concatenar LOCAL_DIR
	if [[ "$REL_ITEM" = /* ]]; then
		REL_ITEM_ABS="$REL_ITEM"
	else
		REL_ITEM_ABS="${LOCAL_DIR}/${REL_ITEM}"
	fi

	# Normalizar
	REL_ITEM_ABS=$(normalize_path "$REL_ITEM_ABS")

	# Validar que esté dentro de LOCAL_DIR (o HOME según corresponda)
	if [[ "$REL_ITEM_ABS" != "$LOCAL_DIR"* ]]; then
		log_error "--item apunta fuera de \$HOME o contiene path traversal: $REL_ITEM_ABS"
		log_debug "Ruta absoluta del item fuera de LOCAL_DIR: $REL_ITEM_ABS"
		exit 1
	fi

}

# Función para sincronizar un elemento
# ---------------------------------------------------
# Ejecuta el comando rsync con o sin timeout
# y guarda la salida en un archivo temporal.
#
# Parámetros:
#   $1 -> archivo donde guardar la salida de rsync
#   $@ -> resto de argumentos (el comando rsync completo)
#
# Retorno:
#   Devuelve el código de salida real de rsync
# ---------------------------------------------------
run_rsync() {
    local output_file="$1"   # Archivo temporal
    shift                    # Quitamos el primer parámetro
    local timeout_minutes=${TIMEOUT_MINUTES:-30}  # Por defecto 30 minutos
    local rc=0               # Aquí guardaremos el código de salida

    if command -v timeout >/dev/null 2>&1 && [ $DRY_RUN -eq 0 ]; then
        # Si existe el comando timeout y no estamos en simulación (dry-run)
        if command -v stdbuf >/dev/null 2>&1; then
            # stdbuf evita que la salida se acumule en memoria
            timeout ${timeout_minutes}m stdbuf -oL -eL "$@" > >(tee "$output_file") 2>&1
        else
            timeout ${timeout_minutes}m "$@" > >(tee "$output_file") 2>&1
        fi
        rc=$?   # Guardamos el código de salida de rsync/timeout
    else
        # Si no hay timeout o estamos en dry-run
        if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL "$@" > >(tee "$output_file") 2>&1
        else
            "$@" > >(tee "$output_file") 2>&1
        fi
        rc=$?
    fi

    return $rc
}

# ---------------------------------------------------
# Analiza la salida de rsync guardada en un archivo
# y actualiza contadores globales.
#
# Parámetros:
#   $1 -> archivo con la salida de rsync
#
# Variables globales que actualiza:
#   ELEMENTOS_PROCESADOS
#   ARCHIVOS_TRANSFERIDOS
#   ARCHIVOS_BORRADOS (si DELETE=1)
#
# Variables "exportadas" para el caller:
#   CREADOS, ACTUALIZADOS, COUNT
# ---------------------------------------------------
analyze_rsync_output() {
    local file="$1"
    local creados actualizados borrados count

    # Contar archivos creados y actualizados
    creados=$(grep '^>f' "$file" | wc -l)
    actualizados=$(grep '^>f.st' "$file" | wc -l)
    count=$(grep -E '^[<>].' "$file" | wc -l)

    log_debug "Archivos creados: $creados, actualizados: $actualizados"

    # Contar borrados solo si se usa --delete
    if [ $DELETE -eq 1 ]; then
        borrados=$(grep '^\*deleting' "$file" | wc -l)
        ARCHIVOS_BORRADOS=$((ARCHIVOS_BORRADOS + borrados))
        log_info "Archivos borrados: $borrados"
    fi

    # Actualizar contadores globales
    ARCHIVOS_TRANSFERIDOS=$((ARCHIVOS_TRANSFERIDOS + count))
    ELEMENTOS_PROCESADOS=$((ELEMENTOS_PROCESADOS + 1))

    # Guardar en variables que puede usar la función principal
    printf -v CREADOS "%s" "$creados"
    printf -v ACTUALIZADOS "%s" "$actualizados"
    printf -v COUNT "%s" "$count"
}

# ---------------------------------------------------
# Sincroniza un elemento (archivo o carpeta) entre
# la carpeta local y pCloud, según el modo elegido.
#
# Parámetros:
#   $1 -> elemento a sincronizar
# ---------------------------------------------------
sincronizar_elemento() {
    local elemento="$1"
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

    log_debug "Sincronizando elemento: $elemento"

    # Preparar rutas según el modo (subir/bajar)
    if [ "$MODO" = "subir" ]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${PCLOUD_DIR}/${elemento}"
        direccion="LOCAL → PCLOUD (Subir)"
    else
        origen="${PCLOUD_DIR}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
        direccion="PCLOUD → LOCAL (Bajar)"
    fi

    # Verificar si el origen existe
    if [ ! -e "$origen" ]; then
        log_warn "No existe $origen"
        return 1
    fi

    # Normalizar si es directorio
    if [ -d "$origen" ]; then
        origen="${origen%/}/"
        destino="${destino%/}/"
    fi

    # Advertencia si tiene espacios
    if [[ "$elemento" =~ [[:space:]] ]]; then
        log_warn "El elemento contiene espacios: '$elemento'"
    fi

    # Crear directorio destino si no existe
    local dir_destino
    dir_destino=$(dirname "$destino")
    if [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$dir_destino"
        log_info "Directorio creado: $dir_destino"
    elif [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 1 ]; then
        log_info "SIMULACIÓN: Se crearía directorio: $dir_destino"
    fi

    log_info "Sincronizando: $elemento ($direccion)"

    # Construir y validar opciones de rsync
    construir_opciones_rsync
    validate_rsync_opts || { log_error "RSYNC_OPTS inválido"; return 1; }

    local RSYNC_CMD=(rsync "${RSYNC_OPTS[@]}" "$origen" "$destino")

    # Crear archivo temporal para capturar salida
    local temp_output
    temp_output=$(mktemp)
    TEMP_FILES+=("$temp_output")

    # Ejecutar rsync con ayuda de run_rsync
    run_rsync "$temp_output" "${RSYNC_CMD[@]}"
    local rc=$?

    # Analizar salida
    analyze_rsync_output "$temp_output"

    # Limpiar archivo temporal
    rm -f "$temp_output"
    TEMP_FILES=("${TEMP_FILES[@]/$temp_output}")

    # Resultado
    if [ $rc -eq 0 ]; then
        log_info "Archivos creados: $CREADOS"
        log_info "Archivos actualizados: $ACTUALIZADOS"
        log_success "Sincronización completada: $elemento ($COUNT archivos transferidos)"
        return 0
    elif [ $rc -eq 124 ]; then
        log_error "TIMEOUT: La sincronización de '$elemento' excedió el límite"
        ERRORES_SINCRONIZACION=$((ERRORES_SINCRONIZACION + 1))
        return 1
    else
        log_error "Error en sincronización: $elemento (código: $rc)"
        ERRORES_SINCRONIZACION=$((ERRORES_SINCRONIZACION + 1))
        return $rc
    fi
}

# =========================
# Funciones modulares para sincronización
# =========================
verificar_precondiciones() {
    log_debug "Verificando precondiciones..."
    
    # Verificar pCloud montado
    if ! verificar_pcloud_montado; then
        log_error "Fallo en verificación de pCloud montado - abortando"
        return 1
    else
        log_info "✓ Verificación de pCloud montado: OK"
    fi
    
    # Verificar conectividad (solo advertencia)
    verificar_conectividad_pcloud
    
    # Verificar espacio en disco (solo en modo ejecución real)
    if [ $DRY_RUN -eq 0 ]; then
        if ! verificar_espacio_disco 500; then
            log_error "Fallo en verificación de espacio en disco - abortando"
            return 1
        else
            log_info "✓ Verificación de espacio en disco: OK"
        fi
    else
        log_debug "Modo dry-run: omitiendo verificación de espacio"
    fi
    
    log_info "Todas las precondiciones verificadas correctamente"
    return 0
}

procesar_elementos() {
    local exit_code=0
    
    if [ ${#ITEMS_ESPECIFICOS[@]} -gt 0 ]; then
        log_info "Sincronizando ${#ITEMS_ESPECIFICOS[@]} elementos específicos"
        for elemento in "${ITEMS_ESPECIFICOS[@]}"; do
            resolver_item_relativo "$elemento"
            log_debug "Procesando elemento: $elemento (relativo: $REL_ITEM)"
            
            if [ -n "$REL_ITEM" ]; then
                sincronizar_elemento "$REL_ITEM" || exit_code=1
                ELEMENTOS_PROCESADOS=$((ELEMENTOS_PROCESADOS + 1))
            else
                log_error "Elemento '$elemento' no válido o vacío después de resolución"
                exit_code=1
            fi
            echo "------------------------------------------"
        done
    else
        log_info "Procesando lista de sincronización: ${LISTA_SINCRONIZACION}"
        while IFS= read -r linea || [ -n "$linea" ]; do
            [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue # Omite comentarios 
            [[ -z "${linea// }" ]] && continue  # Omite líneas vacías o solo espacios           
            log_debug "Procesando elemento de lista: $linea"
            sincronizar_elemento "$linea" || exit_code=1
            ELEMENTOS_PROCESADOS=$((ELEMENTOS_PROCESADOS + 1))
            echo "------------------------------------------"
        done < "$LISTA_SINCRONIZACION"
    fi

    log_info "Procesados $ELEMENTOS_PROCESADOS elementos con código de salida: $exit_code"
    return $exit_code
}

manejar_enlaces_simbolicos() {
    log_info "Manejando enlaces simbólicos..."
    
    if [ "$MODO" = "subir" ]; then
        log_debug "Creando archivo temporal para enlaces"
        tmp_links=$(mktemp --tmpdir sync_links.XXXXXX)
        chmod 600 "$tmp_links"
        TEMP_FILES+=("$tmp_links")
        
        if generar_archivo_enlaces "$tmp_links"; then
            log_info "✓ Archivo de enlaces generado correctamente"
        else
            log_error "Error al generar archivo de enlaces"
            return 1
        fi
    else
        log_debug "Modo bajar: recreando enlaces desde archivo"
        if recrear_enlaces_desde_archivo; then
            log_info "✓ Enlaces recreados correctamente"
        else
            log_error "Error al recrear enlaces desde archivo"
            return 1
        fi
    fi
    
    return 0
}

# Función principal de sincronización
sincronizar() {
    local exit_code=0

    log_info "Iniciando proceso de sincronización en modo: $MODO"
    
    # Verificaciones previas
    if ! verificar_precondiciones; then
        log_error "Fallo en las precondiciones, abortando sincronización"
        return 1
    fi

    # Confirmación de ejecución (solo si no es dry-run)
    if [ $DRY_RUN -eq 0 ]; then
        log_debug "Solicitando confirmación de usuario"
        confirmar_ejecucion
    else
        log_debug "Modo dry-run: omitiendo confirmación de usuario"
    fi

    # Procesar elementos
    log_info "Iniciando procesamiento de elementos..."
    if ! procesar_elementos; then
        exit_code=1
        log_warn "Procesamiento de elementos completado con errores"
    else
        log_info "✓ Procesamiento de elementos completado correctamente"
    fi

    # Manejar enlaces simbólicos
    log_info "Iniciando manejo de enlaces simbólicos..."
    if ! manejar_enlaces_simbolicos; then
        exit_code=1
        log_warn "Manejo de enlaces simbólicos completado con errores"
    else
        log_info "✓ Manejo de enlaces simbólicos completado correctamente"
    fi

    log_info "Sincronización completada con código de salida: $exit_code"
    return $exit_code
}

# =========================
# Post: permisos ejecutables al bajar
# =========================
# Funcion para ajustar permisos de ejecución de ficheros indicados
# No se esta usando actualmente
ajustar_permisos_ejecutables() {
    local directorio_base="${LOCAL_DIR}"
    local exit_code=0
    log_debug "Ajustando permisos de ejecución..."

    log_info "Ajustando permisos de ejecución..."
    
    # Procesar cada argumento
    for patron in "$@"; do
        # Determinar el tipo de patrón
        if [[ "$patron" == *"*"* ]]; then
            log_debug "Aplicando patrón: $patron"
            # Es un patrón con comodín (como *.sh)
            local directorio_patron="${directorio_base}/$(dirname "$patron")"
            local archivo_patron
            archivo_patron="$(basename "$patron")"

            if [ -d "$directorio_patron" ]; then
                log_info "Aplicando permisos a: $patron (recursivo)"
                log_debug "Aplicando permisos recursivos en: $directorio_patron para $archivo_patron"
                # Usar find para buscar archivos que coincidan con el patrón
                find "$directorio_patron" -name "$archivo_patron" -type f -exec chmod +x {} \;
            else
                log_warn "El directorio no existe - $directorio_patron"
                exit_code=1
            fi
        else
            # Es una ruta específica
            local ruta_completa="${directorio_base}/${patron}"
            log_debug "Aplicando permisos a ruta específica: $ruta_completa"
            
            # Verificar si la ruta existe
            if [ ! -e "$ruta_completa" ]; then
                log_warn "La ruta no existe - $ruta_completa"
                exit_code=1
                continue
            fi
            
            # Verificar que tenemos permisos de escritura
            if [ ! -w "$ruta_completa" ]; then
                log_warn "Sin permisos de escritura para: $ruta_completa"
                exit_code=1
                continue
            fi

            if [ -f "$ruta_completa" ]; then
                # Es un archivo específico
                log_info "Aplicando permisos a: $patron"
                log_debug "Aplicando chmod +x a: $ruta_completa"
                chmod +x "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                # Es un directorio específico - aplicar recursivamente
                log_info "Aplicando permisos recursivos a: $patron"
                log_debug "Aplicando permisos recursivos en directorio: $ruta_completa"
                find "$ruta_completa" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.jl" \) -exec chmod +x {} \;
            fi
        fi
    done

    return $exit_code
}

# =========================
# Tests unitarios
# =========================
run_tests() {
    echo "Ejecutando tests unitarios..."
    local tests_passed=0
    local tests_failed=0

    # Test 1: normalize_path
    echo "Test 1: normalize_path"
    local result
    result=$(normalize_path "/home/user/../user/./file.txt")
    if [[ "$result" == */file.txt ]]; then
        echo "PASS: normalize_path"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL: normalize_path - Esperaba path normalizado, obtuve: $result"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 2: get_pcloud_dir
    echo "Test 2: get_pcloud_dir"
    BACKUP_DIR_MODE="comun"
    local pcloud_dir_comun=$(get_pcloud_dir)
    BACKUP_DIR_MODE="readonly"
    local pcloud_dir_readonly=$(get_pcloud_dir)
    
    if [[ "$pcloud_dir_comun" == "$PCLOUD_BACKUP_COMUN" && "$pcloud_dir_readonly" == "$PCLOUD_BACKUP_READONLY" ]]; then
        echo "PASS: get_pcloud_dir"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL: get_pcloud_dir - comun: $pcloud_dir_comun, readonly: $pcloud_dir_readonly"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 3: construir_opciones_rsync
    echo "Test 3: construir_opciones_rsync"
    # Probar diferentes combinaciones de opciones
    OVERWRITE=0
    DRY_RUN=0
    DELETE=0
    USE_CHECKSUM=0
    BW_LIMIT=""
    construir_opciones_rsync
    local base_opts="${RSYNC_OPTS[*]}"
    
    OVERWRITE=1
    construir_opciones_rsync
    local overwrite_opts="${RSYNC_OPTS[*]}"
    
    DELETE=1
    construir_opciones_rsync
    local delete_opts="${RSYNC_OPTS[*]}"
    
    # Verificar que las opciones cambian según los flags
    if [[ "$base_opts" != "$overwrite_opts" && "$base_opts" != "$delete_opts" ]]; then
        echo "PASS: construir_opciones_rsync"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL: construir_opciones_rsync - las opciones no cambian correctamente"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 4: resolver_item_relativo
    echo "Test 4: resolver_item_relativo"
    LOCAL_DIR="/home/testuser"
    resolver_item_relativo "documents/file.txt"
    if [ "$REL_ITEM" = "documents/file.txt" ]; then
        echo "PASS: resolver_item_relativo (ruta relativa)"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL: resolver_item_relativo - Esperaba 'documents/file.txt', obtuve '$REL_ITEM'"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 5: verificación de argumentos duplicados
    echo "Test 5: detección de argumentos duplicados"
    declare -A test_seen_opts
    test_seen_opts=()
    local test_args=("--subir" "--subir" "--delete")
    local duplicate_detected=0
    
    for arg in "${test_args[@]}"; do
        if [[ "$arg" == --* ]]; then
            if [[ -v test_seen_opts[$arg] ]]; then
                duplicate_detected=1
                break
            fi
            test_seen_opts["$arg"]=1
        fi
    done
    
    if [ $duplicate_detected -eq 1 ]; then
        echo "PASS: detección de argumentos duplicados"
        tests_passed=$((tests_passed + 1))
    else
        echo "FAIL: no se detectaron argumentos duplicados cuando debería"
        tests_failed=$((tests_failed + 1))
    fi

    # Test 6: verificar_espacio_disco (test básico)
    echo "Test 6: verificar_espacio_disco (test básico)"
    if verificar_espacio_disco 1 >/dev/null 2>&1; then
        echo "PASS: verificar_espacio_disco (debería tener al menos 1MB)"
        tests_passed=$((tests_passed + 1))
    else
        echo "SKIP: verificar_espacio_disco - no hay espacio suficiente para test"
    fi

    # Resumen de tests
    echo ""
    echo "=========================================="
    echo "RESUMEN DE TESTS"
    echo "=========================================="
    echo "Tests pasados: $tests_passed"
    echo "Tests fallados: $tests_failed"
    echo "Total tests: $((tests_passed + tests_failed))"
    
    return $tests_failed
}

# =========================
# Args
# Procesamiento de argumentos
# =========================

# Procesar los argumentos usando la función
procesar_argumentos "$@"

# Banner de cabecera
mostrar_banner

# Establecer locking (si llegamos aquí, no es modo ayuda)
if ! establecer_lock; then
    exit 1
fi

# Validación final
if [ -z "$MODO" ]; then
    log_error "Debes especificar --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

# =========================
# Función principal
# Mostrar información de debugging si está habilitado
# =========================
verificar_dependencias
find_config_files
verificar_archivos_configuracion

# Añadir esta verificación antes de iniciar la sincronización
if ! verificar_elementos_configuracion; then
    log_error "Error en la configuración. Ejecución abortada."
    eliminar_lock
    exit 1
fi

inicializar_log

# Limpieza de temporales al salir
if [ $VERBOSE -eq 1 ]; then
    log_debug "Modo verboso activado"
    log_debug "Directorio del script: $SCRIPT_DIR"
    log_debug "Directorio local: $LOCAL_DIR"
    log_debug "Directorio pCloud: $(get_pcloud_dir)"
    log_debug "Archivo de lista: $LISTA_SINCRONIZACION"
    log_debug "Archivo de exclusiones: $EXCLUSIONES"
fi

cleanup() {
    for tf in "${TEMP_FILES[@]:-}"; do
        if [ -n "$tf" ] && [ -f "$tf" ]; then
            rm -f "$tf"
            log_debug "Eliminado temporal: $tf"
        fi
    done
}
trap cleanup EXIT INT TERM

sincronizar
exit_code=$?

# Eliminar el lock antes de mostrar el resumen
eliminar_lock_final

#echo ""
mostrar_estadísticas

# Enviar notificación de finalización
notificar_finalizacion $exit_code

# Mantener el log del resumen en el archivo de log también
{
    echo "=========================================="
    echo "Sincronización finalizada: $(date)"
    echo "Elementos procesados: $ELEMENTOS_PROCESADOS"
    echo "Archivos transferidos: $ARCHIVOS_TRANSFERIDOS" 
    [ $DELETE -eq 1 ] && echo "Archivos borrados: $ARCHIVOS_BORRADOS"
    [ ${#EXCLUSIONES_CLI[@]} -gt 0 ] && echo "Exclusiones CLI aplicadas: ${#EXCLUSIONES_CLI[@]}"
    echo "Modo dry-run: $([ $DRY_RUN -eq 1 ] && echo 'Sí' || echo 'No')"
    echo "Enlaces detectados/guardados: $ENLACES_DETECTADOS"
    echo "Enlaces creados: $ENLACES_CREADOS"
    echo "Enlaces existentes: $ENLACES_EXISTENTES"
    echo "Enlaces con errores: $ENLACES_ERRORES"
    echo "Errores generales: $ERRORES_SINCRONIZACION"
    echo "Log: $LOG_FILE"
    echo "=========================================="
} >> "$LOG_FILE"

exit $exit_code# Añadir esta verificación antes de iniciar la sincronización
if ! verificar_elementos_configuracion; then
    log_error "Error en la configuración. Ejecución abortada."
    eliminar_lock
    exit 1
fi
