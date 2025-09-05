#!/usr/bin/env bash
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

# Obtener el hostname de la máquina
# Usar FQDN en lugar del nombre corto (cambio mínimo solicitado)
HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")

# Hostname de la maquina virtual de RTVA
HOSTNAME_RTVA="feynman.rtva.dnf"

# Archivos de configuración (buscar en el directorio del script primero, luego en el directorio actual)
LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="$HOME/sync_bidireccional.log"

# Enlaces simbólicos en la subida, origen
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

# Variables de control
MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"
USE_CHECKSUM=0

# Variables para estadísticas
declare -i ARCHIVOS_SINCRONIZADOS=0
declare -i ERRORES_SINCRONIZACION=0

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
    if command -v curl >/dev/null 2>&1; then
        if ! timeout 5s curl -s https://www.pcloud.com/ > /dev/null; then
            echo "ADVERTENCIA: No se pudo conectar a pCloud. Verifica tu conexión a Internet."
            registrar_log "ADVERTENCIA: No se pudo verificar conectividad con pCloud"
        fi
    else
        echo "ADVERTENCIA: curl no disponible, omitiendo verificación de conectividad"
        registrar_log "ADVERTENCIA: curl no disponible, omitiendo verificación de conectividad"
    fi
}

# Buscar archivos de configuración
find_config_files() {
    # Determinar el nombre del archivo de lista según el hostname
    local lista_por_defecto="sync_bidireccional_directorios.ini"
    local lista_especifica="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"
    
    # Si el hostname es "${HOSTNAME_RTVA}", usar el archivo específico
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${lista_especifica}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_especifica}"
        elif [ -f "./${lista_especifica}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${lista_especifica}"
        else
            echo "ERROR: No se encontró el archivo de lista específico '${lista_especifica}'"
            echo "Busca en:"
            echo "  - ${SCRIPT_DIR}/"
            echo "  - $(pwd)/"
            exit 1
        fi
    else
        # Para otros hostnames, usar el archivo por defecto
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${lista_por_defecto}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_por_defecto}"
        elif [ -f "./${lista_por_defecto}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${lista_por_defecto}"
        fi
    fi
    
    # Validar que el archivo de lista existe
    if [ -n "$LISTA_SINCRONIZACION" ] && [ ! -f "$LISTA_SINCRONIZACION" ]; then
        echo "ERROR: El archivo de lista no existe: $LISTA_SINCRONIZACION"
        exit 1
    fi
    
    # Buscar archivo de exclusiones (igual para todos los hosts)
    if [ -f "${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini"
    elif [ -f "./sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="./sync_bidireccional_exclusiones.ini"
    fi
    
    # Validar que el archivo de exclusiones existe si se especificó
    if [ -n "$EXCLUSIONES" ] && [ ! -f "$EXCLUSIONES" ]; then
        echo "ERROR: El archivo de exclusiones no existe: $EXCLUSIONES"
        exit 1
    fi
}

# Función para mostrar ayuda
mostrar_ayuda() {
    echo "Uso: $0 [OPCIONES]"
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
    echo "  --overwrite        Sobrescribe todos los archivos en destino (no usa --update)"
    echo "  --checksum         Fuerza comparación con checksum (más lento)"  
    echo "  --help             Muestra esta ayuda"
    echo ""
    echo "Archivos de configuración:"
    echo "  - Directorio del script: ${SCRIPT_DIR}/"
    echo "  - Directorio actual: $(pwd)/"
    
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        echo "  - Busca: sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini (específico para este host)"
    else
        echo "  - Busca: sync_bidireccional_directorios.ini (por defecto)"
    fi
    
    echo "  - Busca: sync_bidireccional_exclusiones.ini"
    echo ""
    echo "Hostname detectado: ${HOSTNAME}"
    echo ""
    echo "Ejemplos:"
    echo "  ./sync_bidireccional.sh --subir"
    echo "  ./sync_bidireccional.sh --bajar --dry-run"
    echo "  ./sync_bidireccional.sh --subir --delete --yes"
    echo "  ./sync_bidireccional.sh --subir --item documentos/"
    echo "  ./sync_bidireccional.sh --bajar --item configuracion.ini --dry-run"
    echo "  ./sync_bidireccional.sh --bajar --backup-dir --yes"
    echo "  ./sync_bidireccional.sh --bajar --backup-dir --item documentos/ --yes"
    echo "  ./sync_bidireccional.sh --subir --overwrite  # Sobrescribe todos los archivos"
}

# Función para verificar si pCloud está montado
verificar_pcloud_montado() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(normalize_path "$(get_pcloud_dir)")

    # Verificar si el punto de montaje de pCloud existe
    if [ ! -d "$PCLOUD_MOUNT_POINT" ]; then
        echo "ERROR: El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT"
        echo "Asegúrate de que pCloud Drive esté instalado y ejecutándose."
        exit 1
    fi
    
    # Verificación más robusta: comprobar si pCloud está realmente montado
    # 1. Verificar si el directorio está vacío (puede indicar que no está montado)
    if [ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]; then
        echo "ERROR: El directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT"
        echo "Esto sugiere que pCloud Drive no está montado correctamente."
        exit 1
    fi

    # 2. Verificar usando el comando mount
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt -rno TARGET "$PCLOUD_MOUNT_POINT" >/dev/null 2>&1; then
            echo "ERROR: pCloud no aparece montado en $PCLOUD_MOUNT_POINT"
            exit 1
        fi
    elif command -v mountpoint >/dev/null 2>&1; then
        if ! mountpoint -q "$PCLOUD_MOUNT_POINT"; then
            echo "ERROR: pCloud no aparece montado en $PCLOUD_MOUNT_POINT"
            exit 1
        fi
    else
        if ! mount | grep -qi "pcloud"; then
            echo "ERROR: pCloud no aparece en la lista de sistemas montados"
            exit 1
        fi
    fi
    
    # Verificación adicional con df (más genérica)
    if ! df -P "$PCLOUD_MOUNT_POINT" >/dev/null 2>&1; then
        echo "ERROR: pCloud no está montado correctamente en $PCLOUD_MOUNT_POINT"
        exit 1
    fi
    
    # Verificar si el directorio específico de pCloud existe
    if [ ! -d "$PCLOUD_DIR" ]; then
        echo "ERROR: El directorio de pCloud no existe: $PCLOUD_DIR"
        echo "Asegúrate de que:"
        echo "1. pCloud Drive esté ejecutándose"
        echo "2. Tu cuenta de pCloud esté sincronizada"
        echo "3. El directorio exista en tu pCloud"
        exit 1
    fi
    
    # Verificación adicional: intentar escribir en el directorio (solo si no es dry-run y no es modo backup-dir)
    if [ $DRY_RUN -eq 0 ] && [ "$BACKUP_DIR_MODE" = "comun" ]; then
        local test_file="${PCLOUD_DIR}/.test_write_$$"
        if ! touch "$test_file" 2>/dev/null; then
            echo "ERROR: No se puede escribir en: $PCLOUD_DIR"
            exit 1
        fi
        rm -f "$test_file"
    fi

    echo "✓ Verificación de pCloud: OK - El directorio está montado vàccesible"
}

# Función para mostrar el banner informativo
mostrar_banner() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

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
        echo -e "ESTADO: ${GREEN}MODO SIMULACIÓN${NC} (no se realizarán cambios)"
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

    if [ -n "$ITEM_ESPECIFICO" ]; then
        echo "ELEMENTO ESPECÍFICO: $ITEM_ESPECIFICO"
    else
        echo "LISTA: ${LISTA_SINCRONIZACION:-No encontrada}"
    fi

    echo "EXCLUSIONES: ${EXCLUSIONES:-No encontradas}"
    echo "=========================================="
}

# Función para confirmar la ejecución
confirmar_ejecucion() {
    if [ $YES -eq 1 ]; then
        echo "Confirmación automática (--yes): se procede con la sincronización"
        return
    fi
    
    echo ""
    if [ -t 0 ]; then
        read -r -p "¿Desea continuar con la sincronización? [s/N]: " respuesta
        if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
            echo "Operación cancelada por el usuario."
            exit 0
        fi
        echo ""
    else
        echo "ERROR: No hay entrada interactiva disponible (usa --yes)"
        exit 1
    fi
    echo ""
}

# Función para verificar y crear archivo de log
inicializar_log() {
    # Truncar log si supera 5MB (compatible con macOS y Linux)
    if [ -f "$LOG_FILE" ]; then
        if [ "$(uname)" = "Darwin" ]; then
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
        [ -n "$ITEM_ESPECIFICO" ] && echo "Item específico: $ITEM_ESPECIFICO"
        echo "Lista sincronización: ${LISTA_SINCRONIZACION:-No encontrada}"
        echo "Exclusiones: ${EXCLUSIONES:-No encontradas}"
    } >> "$LOG_FILE"
}

# Función para registrar en log
registrar_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# Función para verificar dependencias
verificar_dependencias() {
    if ! command -v rsync &>/dev/null; then
        echo "ERROR: rsync no está instalado. Instálalo con:"
        echo "sudo apt install rsync  # Debian/Ubuntu"
        echo "sudo dnf install rsync  # RedHat/CentOS"
        exit 1
    fi
}

# Función para verificar archivos de configuración
verificar_archivos_configuracion() {
    if [ -z "$ITEM_ESPECIFICO" ] && [ -z "$LISTA_SINCRONIZACION" ]; then
        echo "ERROR: No se encontró el archivo de lista 'sync_bidireccional_directorios.ini'"
        echo "Busca en:"
        echo "  - ${SCRIPT_DIR}/"
        echo "  - $(pwd)/"
        echo "O crea un archivo con la lista de rutas a sincronizar o usa --item"
        exit 1
    fi
    
    if [ -z "$EXCLUSIONES" ]; then
        echo "ADVERTENCIA: No se encontró el archivo de exclusiones 'sync_bidireccional_exclusiones.ini'"
        echo "No se aplicarán exclusiones específicas"
    fi
}

# Construye opciones de rsync (en array para evitar problemas de espacios)
declare -a RSYNC_OPTS
construir_opciones_rsync() {
    RSYNC_OPTS=(--recursive --verbose --times --progress --whole-file --no-links)
    [ $OVERWRITE -eq 0 ] && RSYNC_OPTS+=(--update)
    [ $DRY_RUN -eq 1 ] && RSYNC_OPTS+=(--dry-run)
    [ $DELETE -eq 1 ] && RSYNC_OPTS+=(--delete-delay)

    if [ $USE_CHECKSUM -eq 1 ]; then
        RSYNC_OPTS+=(--checksum)
    fi

    # Si existe archivo de exclusiones, preferimos pasarla como --exclude-from para eficiencia
    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        RSYNC_OPTS+=(--exclude-from="$EXCLUSIONES")
    fi
}

# =========================
# Validación y utilidades rsync
# =========================
validate_rsync_opts() {
    for opt in "${RSYNC_OPTS[@]:-}"; do
        # Si por alguna razón aparece la cadena 'rsync' en una opción, abortar
        if printf '%s' "$opt" | grep -qi 'rsync'; then
            echo "ERROR: RSYNC_OPTS contiene un elemento sospechoso con 'rsync': $opt" >&2
            echo "Contenido actual de RSYNC_OPTS:" >&2
            declare -p RSYNC_OPTS >&2
            return 1
        fi
    done
    return 0
}

print_rsync_command() {
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
# Función para generar archivo de enlaces simbólicos
generar_archivo_enlaces() {
    local archivo_enlaces="$1"
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

    echo "Generando archivo de enlaces simbólicos..."
    registrar_log "Generando archivo de enlaces simbólicos: $archivo_enlaces"
    : > "$archivo_enlaces"

    registrar_enlace() {
        local enlace="$1"
        # Solo enlaces simbólicos
        [ -L "$enlace" ] || return

        # Columna 1: ruta del ENLACE relativa a $HOME sin usar realpath (no romper enlaces rotos/relativos)
        local ruta_relativa="$enlace"
        if [[ "$ruta_relativa" == "$LOCAL_DIR/"* ]]; then
            ruta_relativa="${ruta_relativa#${LOCAL_DIR}/}"
        else
            # Fallback si no cuelga de $HOME
            ruta_relativa="${ruta_relativa#/}"
        fi

        # Columna 2: destino tal cual fue creado el enlace (puede ser relativo)
        local destino
        destino="$(readlink "$enlace" 2>/dev/null || true)"

        # Validaciones: no escribir líneas incompletas
        if [ -z "$ruta_relativa" ] || [ -z "$destino" ]; then
            echo "Advertencia: enlace no válido u origen/destino vacío: $enlace"
            registrar_log "Advertencia: enlace no válido u origen/destino vacío: $enlace"
            return
        fi

        printf "%s\t%s\n" "$ruta_relativa" "$destino" >> "$archivo_enlaces"
        echo "Registrado enlace: $ruta_relativa -> $destino"
        registrar_log "Registrado enlace: $ruta_relativa -> $destino"
    }

    buscar_enlaces_en_directorio() {
        local dir="$1"
        [ -d "$dir" ] || return
        # -print0 para máxima robustez por si hay espacios/nuevas líneas raras en nombres
        find "$dir" -type l -print0 2>/dev/null | while IFS= read -r -d '' enlace; do
            registrar_enlace "$enlace"
        done
    }

    if [ -n "$ITEM_ESPECIFICO" ]; then
        local ruta_completa="${LOCAL_DIR}/${ITEM_ESPECIFICO}"
        if [ -L "$ruta_completa" ]; then
            registrar_enlace "$ruta_completa"
        elif [ -d "$ruta_completa" ]; then
            buscar_enlaces_en_directorio "$ruta_completa"
        fi
    else
        while IFS= read -r elemento || [ -n "$elemento" ]; do
            [[ -n "$elemento" && ! "$elemento" =~ ^[[:space:]]*# ]] || continue
            
            # Validación de seguridad adicional
            if [[ "$elemento" == *".."* ]]; then
                echo "ERROR: Elemento contiene '..' - posible path traversal: $elemento"
                registrar_log "ERROR: Elemento contiene '..' - posible path traversal: $elemento"
                continue
            fi
            
            local ruta_completa="${LOCAL_DIR}/${elemento}"
            if [ -L "$ruta_completa" ]; then
                registrar_enlace "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                buscar_enlaces_en_directorio "$ruta_completa"
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    if [ -s "$archivo_enlaces" ]; then
        echo "Sincronizando archivo de enlaces..."
        construir_opciones_rsync
        validate_rsync_opts || { echo "Abortando: RSYNC_OPTS inválido"; return 1; }
        print_rsync_command "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"
        if rsync "${RSYNC_OPTS[@]}" "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"; then
            echo "✓ Archivo de enlaces sincronizado"
            registrar_log "Archivo de enlaces sincronizado: ${PCLOUD_DIR}/${SYMLINKS_FILE}"
        else
            echo "✗ Error sincronizando archivo de enlaces"
            registrar_log "Error sincronizando archivo de enlaces: ${PCLOUD_DIR}/${SYMLINKS_FILE}"
            return 1
        fi
    else
        echo "No se encontraron enlaces simbólicos para registrar"
        registrar_log "No se encontraron enlaces simbólicos para registrar"
    fi

    rm -f "$archivo_enlaces"
}

# Función para recrear enlaces simbólicos 
recrear_enlaces_desde_archivo() {
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)
    local archivo_enlaces_origen="${PCLOUD_DIR}/${SYMLINKS_FILE}"
    local archivo_enlaces_local="${LOCAL_DIR}/${SYMLINKS_FILE}"

    echo "Buscando archivo de enlaces..."
    registrar_log "Buscando archivo de enlaces: $archivo_enlaces_origen"

    if [ -f "$archivo_enlaces_origen" ]; then
        cp -f "$archivo_enlaces_origen" "$archivo_enlaces_local"
        echo "Archivo de enlaces copiado localmente"
        registrar_log "Archivo de enlaces copiado localmente: $archivo_enlaces_local"
    elif [ -f "$archivo_enlaces_local" ]; then
        echo "Usando archivo de enlaces local existente"
        registrar_log "Usando archivo de enlaces local existente: $archivo_enlaces_local"
    else
        echo "No se encontró archivo de enlaces, omitiendo recreación"
        registrar_log "No se encontró archivo de enlaces, omitiendo recreación"
        return
    fi

    echo "Recreando enlaces simbólicos..."
    local contador=0
    local errores=0

    # Leer con separador de TAB
    while IFS=$'\t' read -r ruta_enlace destino || [ -n "$ruta_enlace" ] || [ -n "$destino" ]; do
        # Saltar líneas vacías o mal formateadas
        if [ -z "$ruta_enlace" ] || [ -z "$destino" ]; then
            echo "Línea inválida en meta (se omite)"
            continue
        fi

        local ruta_completa="${LOCAL_DIR}/${ruta_enlace}"
        local dir_padre
        dir_padre=$(dirname "$ruta_completa")

        if [ ! -d "$dir_padre" ] && [ $DRY_RUN -eq 0 ]; then
            mkdir -p "$dir_padre"
        fi

        # Si ya existe y apunta a lo mismo (comparar con readlink SIN -f para respetar destino relativo)
        if [ -L "$ruta_completa" ]; then
            local destino_actual
            destino_actual=$(readlink "$ruta_completa" 2>/dev/null || true)
            if [ "$destino_actual" = "$destino" ]; then
                echo "Enlace ya existe y es correcto: $ruta_enlace -> $destino"
                registrar_log "Enlace ya existe y es correcto: $ruta_enlace -> $destino"
                continue
            fi
        fi

        if [ $DRY_RUN -eq 1 ]; then
            echo "SIMULACIÓN: ln -sfn '$destino' '$ruta_completa'"
            registrar_log "SIMULACIÓN: ln -sfn '$destino' '$ruta_completa'"
            contador=$((contador + 1))
        else
            if ln -sfn "$destino" "$ruta_completa" 2>/dev/null; then
                echo "Creado enlace: $ruta_enlace -> $destino"
                registrar_log "Creado enlace: $ruta_enlace -> $destino"
                contador=$((contador + 1))
            else
                echo "Error creando enlace: $ruta_enlace -> $destino"
                registrar_log "Error creando enlace: $ruta_enlace -> $destino"
                errores=$((errores + 1))
            fi
        fi
    done < "$archivo_enlaces_local"

    echo "Enlaces recreados: $contador, Errores: $errores"
    registrar_log "Enlaces recreados: $contador, Errores: $errores"

    [ $DRY_RUN -eq 0 ] && rm -f "$archivo_enlaces_local"
}

# =========================
# SINCRONIZACIÓN
# =========================
resolver_item_relativo() {
    local item="$1"
    if [ -z "$item" ]; then
        REL_ITEM=""
        return
    fi
    if [[ "$item" = /* ]]; then
        if [[ "$item" == "$LOCAL_DIR/"* ]]; then
            REL_ITEM="${item#${LOCAL_DIR}/}"
        else
            echo "ERROR: --item apunta fuera de \$HOME: $item"
            exit 1
        fi
    else
        REL_ITEM="$item"
    fi
    
    # Validación de seguridad: evitar path traversal
    if [[ "$REL_ITEM" == *".."* ]]; then
        echo "ERROR: El elemento no puede contener '..' por razones de seguridad"
        exit 1
    fi
}

# Función para sincronizar un elemento
sincronizar_elemento() {
    local elemento="$1"
    local PCLOUD_DIR
    PCLOUD_DIR=$(get_pcloud_dir)

    # Definir origen y destino según el modo
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
        echo "ADVERTENCIA: No existe $origen"
        registrar_log "ADVERTENCIA: No existe $origen"
        return 1
    fi
    
    # Determinar si es directorio o archivo
    if [ -d "$origen" ]; then
        origen="${origen%/}/"
        destino="${destino%/}/"
    fi

    # Advertencia si el elemento contiene espacios
    if [[ "$elemento" =~ [[:space:]] ]]; then
        echo "ADVERTENCIA: El elemento contiene espacios: '$elemento'"
        registrar_log "ADVERTENCIA: Elemento con espacios: $elemento"
    fi

    # Crear directorio de destino si no existe (solo si no estamos en dry-run)
    local dir_destino
    dir_destino=$(dirname "$destino")
    if [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$dir_destino"
        echo "Directorio creado: $dir_destino"
        registrar_log "Directorio creado: $dir_destino"
    elif [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 1 ]; then
        echo "SIMULACIÓN: Se crearía directorio: $dir_destino"
        registrar_log "SIMULACIÓN: Se crearía directorio: $dir_destino"
    fi

    echo ""
    echo -e "${BLUE}Sincronizando: $elemento ($direccion)${NC}"
    registrar_log "Sincronizando: $elemento ($direccion)"

    construir_opciones_rsync
    validate_rsync_opts || { echo "Abortando: RSYNC_OPTS inválido"; registrar_log "Abortando: RSYNC_OPTS inválido"; return 1; }

    # Imprimir comando de forma segura
    print_rsync_command "$origen" "$destino"
    registrar_log "Comando ejecutado: rsync ${RSYNC_OPTS[*]} $origen $destino"

    # Ejecutar rsync con timeout si está disponible
    local salida

    # Ejecutar rsync mostrando salida en tiempo real y registrando en el log
    local rc=0

    # Preparar el comando rsync (array para seguridad con espacios)
    local RSYNC_CMD=(rsync "${RSYNC_OPTS[@]}" "$origen" "$destino")

    # Si tenemos timeout disponible, lo envolvemos; usamos tee para mostrar + log
    if command -v timeout >/dev/null 2>&1; then
        if command -v stdbuf >/dev/null 2>&1; then
            # stdbuf para evitar buffering cuando se pipea
            timeout 30m stdbuf -oL -eL "${RSYNC_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
        else
            timeout 30m "${RSYNC_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
        fi
    else
        if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL "${RSYNC_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
        else
            "${RSYNC_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
        fi
    fi

    # Comprobar resultado (rc contiene el exit code real de rsync/timeout)
    if [ $rc -eq 0 ]; then
        echo "✓ Sincronización completada: $elemento"
        registrar_log "Sincronización completada: $elemento"
        ARCHIVOS_SINCRONIZADOS+=1
        return 0
    else
        if [ $rc -eq 124 ]; then
            echo "✗ Error: Timeout en sincronización: $elemento"
            registrar_log "Error: Timeout en sincronización: $elemento"
        else
            echo "✗ Error en sincronización: $elemento (código: $rc)"
            registrar_log "Error en sincronización: $elemento (código: $rc)"
        fi
        ERRORES_SINCRONIZACION+=1
        return $rc
    fi
}

# Función principal de sincronización
sincronizar() {
    local exit_code=0

    mostrar_banner
    
    # Verificar si pCloud está montado antes de continuar
    verificar_pcloud_montado
    
    # Verificar conectividad con pCloud (solo advertencia)
    verificar_conectividad_pcloud

    # Preguntar confirmación antes de continuar (excepto en dry-run o si se usa --yes)
    [ $DRY_RUN -eq 0 ] && confirmar_ejecucion

    # Si se especificó un elemento específico
    if [ -n "$ITEM_ESPECIFICO" ]; then
        resolver_item_relativo "$ITEM_ESPECIFICO"
        echo "Sincronizando elemento específico: $REL_ITEM"
        sincronizar_elemento "$REL_ITEM" || exit_code=1
    else
        echo "Procesando lista de sincronización: ${LISTA_SINCRONIZACION}"
        while IFS= read -r linea || [ -n "$linea" ]; do
            [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue
            
            # Validación de seguridad adicional
            if [[ "$linea" == *".."* ]]; then
                echo "ERROR: Elemento contiene '..' - posible path traversal: $linea"
                registrar_log "ERROR: Elemento contiene '..' - posible path traversal: $linea"
                exit_code=1
                continue
            fi
            
            sincronizar_elemento "$linea" || exit_code=1
            echo "------------------------------------------"
        done < "$LISTA_SINCRONIZACION"
    fi
    
    # Manejo de enlaces simbólicos
    if [ "$MODO" = "subir" ]; then
        # Generar y subir archivo de enlaces
        tmp_links=$(mktemp)
        TEMP_FILES+=("$tmp_links")
        generar_archivo_enlaces "$tmp_links"
    else
        # Recrear enlaces desde archivo
        recrear_enlaces_desde_archivo
    fi

    return $exit_code
}

# =========================
# Post: permisos ejecutables al bajar
# =========================
# Funcion para ajustar permisos de ejecución de ficheros indicados
ajustar_permisos_ejecutables() {
    local directorio_base="${LOCAL_DIR}"
    local exit_code=0

    echo "Ajustando permisos de ejecución..."
    
    # Procesar cada argumento
    for patron in "$@"; do
        # Determinar el tipo de patrón
        if [[ "$patron" == *"*"* ]]; then
            # Es un patrón con comodín (como *.sh)
            local directorio_patron="${directorio_base}/$(dirname "$patron")"
            local archivo_patron
            archivo_patron="$(basename "$patron")"

            if [ -d "$directorio_patron" ]; then
                echo "Aplicando permisos a: $patron (recursivo)"
                # Usar find para buscar archivos que coincidan con el patrón
                find "$directorio_patron" -name "$archivo_patron" -type f -exec chmod +x {} \;
            else
                echo "Advertencia: El directorio no existe - $directorio_patron"
                exit_code=1
            fi
        else
            # Es una ruta específica
            local ruta_completa="${directorio_base}/${patron}"
            
            # Verificar si la ruta existe
            if [ ! -e "$ruta_completa" ]; then
                echo "Advertencia: La ruta no existe - $ruta_completa"
                exit_code=1
                continue
            fi
            
            # Verificar que tenemos permisos de escritura
            if [ ! -w "$ruta_completa" ]; then
                echo "Advertencia: Sin permisos de escritura para: $ruta_completa"
                exit_code=1
                continue
            fi

            if [ -f "$ruta_completa" ]; then
                # Es un archivo específico
                echo "Aplicando permisos a: $patron"
                chmod +x "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                # Es un directorio específico - aplicar recursivamente
                echo "Aplicando permisos recursivos a: $patron"
                find "$ruta_completa" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.jl" \) -exec chmod +x {} \;
            fi
        fi
    done

    return $exit_code
}

# =========================
# Args
# =========================
# Procesar argumentos
if [ $# -eq 0 ]; then
    echo "ERROR: Debes especificar al menos --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --subir)
            [ -n "$MODO" ] && { echo "ERROR: No puedes usar --subir y --bajar simultáneamente"; exit 1; }
            MODO="subir"; shift;;
        --bajar)
            [ -n "$MODO" ] && { echo "ERROR: No puedes usar --subir y --bajar simultáneamente"; exit 1; }
            MODO="bajar"; shift;;
        --delete)
            DELETE=1; shift;;
        --dry-run)
            DRY_RUN=1; shift;;
        --item)
            [ -z "$2" ] && { echo "ERROR: --item requiere un argumento"; exit 1; }
            ITEM_ESPECIFICO="$2"; shift 2;;
        --yes)
            YES=1; shift;;
        --backup-dir)
            BACKUP_DIR_MODE="readonly"; shift;;
        --overwrite)
            OVERWRITE=1; shift;;
        --checksum)
            USE_CHECKSUM=1; shift;;
        -h|--help)
            mostrar_ayuda; exit 0;;
        *)
            echo "ERROR: Opción desconocida: $1"; mostrar_ayuda; exit 1;;
    esac
done

# Validación final
if [ -z "$MODO" ]; then
    echo "ERROR: Debes especificar --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

# =========================
# Main
# =========================
verificar_dependencias
find_config_files
verificar_archivos_configuracion
inicializar_log

# Limpieza de temporales al salir
cleanup() {
    for tf in "${TEMP_FILES[@]:-}"; do
        [ -f "$tf" ] && rm -f "$tf"
    done
}
trap cleanup EXIT

sincronizar
exit_code=$?

echo ""
echo "=========================================="
echo "Sincronización finalizada: $(date)"
echo "Elementos sincronizados: $ARCHIVOS_SINCRONIZADOS"
echo "Errores: $ERRORES_SINCRONIZACION"
echo "Log: $LOG_FILE"
echo "=========================================="

exit $exit_code
