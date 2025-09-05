#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud
# Uso:
#   Subir: ./sync_bidireccional.sh --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite] [--checksum]
#   Bajar: ./sync_bidireccional.sh --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite] [--checksum]

# =========================
# Configuración (ajusta a tu entorno)
# =========================
PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"

LOCAL_DIR="${HOME}"
PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME="$(hostname -s)"   # nombre corto más portable
HOSTNAME_RTVA="feynman.rtva.dnf"

LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="${HOME}/sync_bidireccional.log"
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"
USE_CHECKSUM=0   # opcional

# Archivos temporales a limpiar al salir (aunque el script termine con error)
TEMP_FILES=()

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =========================
# Utilidades básicas
# =========================
get_pcloud_dir() {
    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMUN"
    fi
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
            echo "ERROR: No se encontró el archivo de lista específico '${lista_especifica}'"
            echo "Busca en: ${SCRIPT_DIR}/ o $(pwd)/"
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
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones PRINCIPALES (obligatorio una de ellas):"
    echo "  --subir           Sincroniza desde el directorio local a pCloud (${LOCAL_DIR} → pCloud)"
    echo "  --bajar           Sincroniza desde pCloud al directorio local (pCloud → ${LOCAL_DIR})"
    echo ""
    echo "Opciones SECUNDARIAS (opcionales):"
    echo "  --delete          Elimina en destino los archivos que no existan en origen"
    echo "  --dry-run         Simula la operación sin cambios"
    echo "  --item ELEMENTO   Sincroniza solo el elemento especificado (relativo a \$HOME o absoluto dentro de \$HOME)"
    echo "  --yes             No pregunta confirmación"
    echo "  --backup-dir      Usa pCloud Backup (solo lectura)"
    echo "  --overwrite       Sobrescribe todos los archivos (sin --update)"
    echo "  --checksum        Fuerza comparación con checksum (más lento)"
    echo "  --help            Muestra esta ayuda"
    echo ""
    echo "Hostname detectado: ${HOSTNAME}"
}

verificar_pcloud_montado() {
    local PCLOUD_DIR
    PCLOUD_DIR="$(get_pcloud_dir)"

    if [ ! -d "$PCLOUD_MOUNT_POINT" ]; then
        echo "ERROR: El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT"
        exit 1
    fi
    if [ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]; then
        echo "ERROR: El directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT"
        exit 1
    fi
    if ! command -v findmnt >/dev/null 2>&1; then
        echo "ADVERTENCIA: 'findmnt' no disponible; se omite verificación de montaje"
    else
        if ! findmnt -rno TARGET "$PCLOUD_MOUNT_POINT" >/dev/null 2>&1; then
            echo "ERROR: pCloud no aparece montado en $PCLOUD_MOUNT_POINT"
            exit 1
        fi
    fi
    if [ ! -d "$PCLOUD_DIR" ]; then
        echo "ERROR: El directorio de pCloud no existe: $PCLOUD_DIR"
        exit 1
    fi

    if [ $DRY_RUN -eq 0 ] && [ "$BACKUP_DIR_MODE" = "comun" ]; then
        local test_file="${PCLOUD_DIR}/.test_write_$$"
        if ! touch "$test_file" 2>/dev/null; then
            echo "ERROR: No se puede escribir en: $PCLOUD_DIR"
            exit 1
        fi
        rm -f "$test_file"
    fi

    echo "✓ Verificación de pCloud: OK - El directorio está montado y accesible"
}

mostrar_banner() {
    local PCLOUD_DIR
    PCLOUD_DIR="$(get_pcloud_dir)"
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
    [ $DRY_RUN -eq 1 ] && echo -e "ESTADO: ${GREEN}MODO SIMULACIÓN${NC}"
    [ $DELETE -eq 1 ] && echo -e "BORRADO: ${GREEN}ACTIVADO${NC}"
    [ $YES -eq 1 ] && echo "CONFIRMACIÓN: Automática"
    if [ $OVERWRITE -eq 1 ]; then
        echo -e "SOBRESCRITURA: ${GREEN}ACTIVADA${NC}"
    else
        echo "MODO: SEGURO (--update activado)"
    fi
    if [ $USE_CHECKSUM -eq 1 ]; then
        echo "COMPARACIÓN: checksum (lento)"
    fi
    if [ -n "$ITEM_ESPECIFICO" ]; then
        echo "ELEMENTO ESPECÍFICO: $ITEM_ESPECIFICO"
    else
        echo "LISTA: ${LISTA_SINCRONIZACION:-No encontrada}"
    fi
    echo "EXCLUSIONES: ${EXCLUSIONES:-No encontradas}"
    echo "=========================================="
}

confirmar_ejecucion() {
    if [ $YES -eq 1 ]; then
        echo "Confirmación automática (--yes): se procede con la sincronización"
        return
    fi
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
}

# =========================
# Log
# =========================
inicializar_log() {
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
registrar_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# =========================
# Dependencias y config
# =========================
verificar_dependencias() {
    if ! command -v rsync &>/dev/null; then
        echo "ERROR: rsync no está instalado."
        exit 1
    fi
}

verificar_archivos_configuracion() {
    if [ -z "$ITEM_ESPECIFICO" ] && [ -z "$LISTA_SINCRONIZACION" ]; then
        echo "ERROR: No se encontró archivo de lista de sincronización"
        echo "Crea 'sync_bidireccional_directorios.ini' o usa --item"
        exit 1
    fi
    if [ -z "$EXCLUSIONES" ]; then
        echo "ADVERTENCIA: No se encontró archivo de exclusiones"
    fi
}

# =========================
# Rsync
# =========================
declare -a RSYNC_OPTS
construir_opciones_rsync() {
    RSYNC_OPTS=(--recursive --verbose --times --progress --whole-file --no-links)
    [ $OVERWRITE -eq 0 ] && RSYNC_OPTS+=(--update)
    [ $DRY_RUN -eq 1 ] && RSYNC_OPTS+=(--dry-run)
    [ $DELETE -eq 1 ] && RSYNC_OPTS+=(--delete-delay)
    [ $USE_CHECKSUM -eq 1 ] && RSYNC_OPTS+=(--checksum)

    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        while IFS= read -r linea || [ -n "$linea" ]; do
            [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue
            RSYNC_OPTS+=(--exclude="$linea")
        done < "$EXCLUSIONES"
    fi
}


# Validación de RSYNC_OPTS para evitar que contengan la palabra 'rsync' por error
validate_rsync_opts() {
    for _opt in "${RSYNC_OPTS[@]:-}"; do
        if [[ "$_opt" == *"rsync"* ]]; then
            echo "ERROR: RSYNC_OPTS contiene un elemento con 'rsync' (indica construcción incorrecta): $_opt" >&2
            echo "Contenido actual de RSYNC_OPTS:" >&2
            declare -p RSYNC_OPTS >&2
            exit 1
        fi
    done
}

# =========================
# ENLACES SIMBÓLICOS
# =========================
generar_archivo_enlaces() {
    # Genera un archivo .meta con pares: <ruta_relativa_a_HOME>\t<destino_link_tal_cual>
    local archivo_enlaces="$1"
    local PCLOUD_DIR
    PCLOUD_DIR="$(get_pcloud_dir)"

    echo "Generando archivo de enlaces simbólicos..."
    registrar_log "Generando archivo de enlaces simbólicos: $archivo_enlaces"
    : > "$archivo_enlaces"

    registrar_enlace() {
        local enlace="$1"
        [ -L "$enlace" ] || return

        local ruta_relativa="$enlace"
        if [[ "$ruta_relativa" == "$LOCAL_DIR/"* ]]; then
            ruta_relativa="${ruta_relativa#${LOCAL_DIR}/}"
        else
            ruta_relativa="${ruta_relativa#/}"
        fi

        local destino
        destino="$(readlink "$enlace" 2>/dev/null || true)"
        if [ -z "${ruta_relativa}" ] || [ -z "${destino}" ]; then
            echo "Advertencia: enlace no válido u origen/destino vacío: $enlace"
            registrar_log "Advertencia: enlace no válido u origen/destino vacío: $enlace"
            return
        fi
        printf "%s\t%s\n" "$ruta_relativa" "$destino" >> "$archivo_enlaces"
        registrar_log "Registrado enlace: $ruta_relativa -> $destino"
    }

    buscar_enlaces_en_directorio() {
        local dir="$1"
        [ -d "$dir" ] || return
        find "$dir" -type l -print0 2>/dev/null | while IFS= read -r -d '' enlace; do
            registrar_enlace "$enlace"
        done
    }

    if [ -n "$ITEM_ESPECIFICO" ]; then
        local ruta_item="$ITEM_ESPECIFICO"
        # Soportar rutas absolutas dentro de $HOME
        if [[ "$ruta_item" = /* ]]; then
            if [[ "$ruta_item" == "$LOCAL_DIR/"* ]]; then
                ruta_item="${ruta_item#${LOCAL_DIR}/}"
            else
                echo "ADVERTENCIA: --item absoluto fuera de \$HOME, se omite"
                ruta_item=""
            fi
        fi
        if [ -n "$ruta_item" ]; then
            local ruta_completa="${LOCAL_DIR}/${ruta_item}"
            if [ -L "$ruta_completa" ]; then
                registrar_enlace "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                buscar_enlaces_en_directorio "$ruta_completa"
            fi
        fi
    else
        while IFS= read -r elemento || [ -n "$elemento" ]; do
            [[ -n "$elemento" && ! "$elemento" =~ ^[[:space:]]*# ]] || continue
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
        if [ $DRY_RUN -eq 1 ]; then
            validate_rsync_opts
    printf -v rsync_cmd "rsync %q " "${RSYNC_OPTS[@]}" "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"
            echo "SIMULACIÓN: $rsync_cmd"
            registrar_log "SIMULACIÓN: $rsync_cmd"
        else
            if rsync "${RSYNC_OPTS[@]}" "$archivo_enlaces" "${PCLOUD_DIR}/${SYMLINKS_FILE}"; then
                echo "✓ Archivo de enlaces sincronizado"
                registrar_log "Archivo de enlaces sincronizado: ${PCLOUD_DIR}/${SYMLINKS_FILE}"
            else
                echo "✗ Error sincronizando archivo de enlaces"
                registrar_log "Error sincronizando archivo de enlaces: ${PCLOUD_DIR}/${SYMLINKS_FILE}"
            fi
        fi
    else
        echo "No se encontraron enlaces simbólicos para registrar"
        registrar_log "No se encontraron enlaces simbólicos para registrar"
    fi
}

recrear_enlaces_desde_archivo() {
    local PCLOUD_DIR
    PCLOUD_DIR="$(get_pcloud_dir)"
    local archivo_enlaces_origen="${PCLOUD_DIR}/${SYMLINKS_FILE}"
    local archivo_enlaces_local="${LOCAL_DIR}/${SYMLINKS_FILE}"

    echo "Buscando archivo de enlaces..."
    registrar_log "Buscando archivo de enlaces: $archivo_enlaces_origen"

    if [ -f "$archivo_enlaces_origen" ]; then
        cp -f "$archivo_enlaces_origen" "$archivo_enlaces_local"
        registrar_log "Archivo de enlaces copiado localmente: $archivo_enlaces_local"
    elif [ -f "$archivo_enlaces_local" ]; then
        registrar_log "Usando archivo de enlaces local existente: $archivo_enlaces_local"
    else
        echo "No se encontró archivo de enlaces, omitiendo recreación"
        registrar_log "No se encontró archivo de enlaces, omitiendo recreación"
        return
    fi

    echo "Recreando enlaces simbólicos..."
    local contador=0
    local errores=0

    while IFS=$'\t' read -r ruta_enlace destino || [ -n "${ruta_enlace:-}" ] || [ -n "${destino:-}" ]; do
        if [ -z "${ruta_enlace:-}" ] || [ -z "${destino:-}" ]; then
            echo "Línea inválida en meta (se omite)"
            continue
        fi
        local ruta_completa="${LOCAL_DIR}/${ruta_enlace}"
        local dir_padre
        dir_padre="$(dirname "$ruta_completa")"
        if [ ! -d "$dir_padre" ] && [ $DRY_RUN -eq 0 ]; then
            mkdir -p "$dir_padre"
        fi
        if [ -L "$ruta_completa" ]; then
            local destino_actual
            destino_actual="$(readlink "$ruta_completa" 2>/dev/null || true)"
            if [ "$destino_actual" = "$destino" ]; then
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
                registrar_log "Creado enlace: $ruta_enlace -> $destino"
                contador=$((contador + 1))
            else
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
# Sincronización
# =========================
# Resuelve --item para soportar absolutos dentro de $HOME; devuelve en variable global REL_ITEM
resolver_item_relativo() {
    local item="$1"
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
}

sincronizar_elemento() {
    local elemento="$1"
    local PCLOUD_DIR origen destino direccion

    if [ -z "$elemento" ]; then
        echo "ADVERTENCIA: Elemento vacío, se omite"
        return 1
    fi

    PCLOUD_DIR="$(get_pcloud_dir)"

    if [ "$MODO" = "subir" ]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${PCLOUD_DIR}/${elemento}"
        direccion="LOCAL → PCLOUD (Subir)"
    else
        origen="${PCLOUD_DIR}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
        direccion="PCLOUD → LOCAL (Bajar)"
    fi

    if [ ! -e "$origen" ]; then
        echo "ADVERTENCIA: No existe $origen"
        registrar_log "ADVERTENCIA: No existe $origen"
        return 1
    fi

    if [ -d "$origen" ]; then
        origen="${origen}/"
        destino="${destino}/"
    fi

    local dir_destino
    dir_destino="$(dirname "$destino")"
    if [ ! -d "$dir_destino" ]; then
        if [ $DRY_RUN -eq 0 ]; then
            mkdir -p "$dir_destino"
            registrar_log "Directorio creado: $dir_destino"
        else
            registrar_log "SIMULACIÓN: Se crearía directorio: $dir_destino"
        fi
    fi

    echo ""
    echo -e "${BLUE}Sincronizando: $elemento ($direccion)${NC}"
    registrar_log "Sincronizando: $elemento ($direccion)"

    construir_opciones_rsync
    validate_rsync_opts
    printf -v rsync_cmd "rsync %q " "${RSYNC_OPTS[@]}" "$origen" "$destino"
    echo "Comando: $rsync_cmd"
    registrar_log "Comando ejecutado: $rsync_cmd"

    if salida=$(rsync "${RSYNC_OPTS[@]}" "$origen" "$destino" 2>&1); then
        echo "✓ Sincronización completada: $elemento"
        registrar_log "Sincronización completada: $elemento"
        return 0
    else
        local rc=$?
        echo "✗ Error en sincronización: $elemento (código: $rc)"
        registrar_log "Error en sincronización: $elemento (código: $rc) - salida: $salida"
        return $rc
    fi
}

sincronizar() {
    local exit_code=0

    mostrar_banner
    verificar_pcloud_montado
    [ $DRY_RUN -eq 0 ] && confirmar_ejecucion

    if [ -n "$ITEM_ESPECIFICO" ]; then
        resolver_item_relativo "$ITEM_ESPECIFICO"
        echo "Sincronizando elemento específico: $REL_ITEM"
        sincronizar_elemento "$REL_ITEM" || exit_code=1
    else
        echo "Procesando lista de sincronización: ${LISTA_SINCRONIZACION}"
        [ -s "$LISTA_SINCRONIZACION" ] || { echo "Lista vacía"; return 1; }
        while IFS= read -r linea || [ -n "$linea" ]; do
            [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]] || continue
            sincronizar_elemento "$linea" || exit_code=1
            echo "------------------------------------------"
        done < "$LISTA_SINCRONIZACION"
    fi

    if [ "$MODO" = "subir" ]; then
        local tmp_links
        tmp_links="$(mktemp)"
        TEMP_FILES+=("$tmp_links")
        generar_archivo_enlaces "$tmp_links"
    else
        recrear_enlaces_desde_archivo
    fi

    return $exit_code
}

# =========================
# Post: permisos ejecutables al bajar
# =========================
ajustar_permisos_ejecutables() {
    local directorio_base="${LOCAL_DIR}" exit_code=0
    echo "Ajustando permisos de ejecución..."
    for patron in "$@"; do
        if [[ "$patron" == *"*"* ]]; then
            local directorio_patron="${directorio_base}/$(dirname "$patron")"
            local archivo_patron
            archivo_patron="$(basename "$patron")"
            if [ -d "$directorio_patron" ]; then
                echo "Aplicando permisos a: $patron (recursivo)"
                find "$directorio_patron" -name "$archivo_patron" -type f -exec chmod +x {} \;
            else
                echo "Advertencia: El directorio no existe - $directorio_patron"
                exit_code=1
            fi
        else
            local ruta_completa="${directorio_base}/${patron}"
            if [ ! -e "$ruta_completa" ]; then
                echo "Advertencia: La ruta no existe - $ruta_completa"
                exit_code=1
                continue
            fi
            if [ -f "$ruta_completa" ]; then
                echo "Aplicando permisos a: $patron"
                chmod +x "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                echo "Aplicando permisos recursivos a: $patron"
                find "$ruta_completa" -type f \( -name "*.sh" -o -name "*.bash" \) -exec chmod +x {} \;
            fi
        fi
    done
    return $exit_code
}

# =========================
# Args parsing
# =========================
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
        --delete) DELETE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --item)
            [ $# -lt 2 ] && { echo "ERROR: La opción --item requiere un argumento"; exit 1; }
            ITEM_ESPECIFICO="$2"; shift 2;;
        --yes) YES=1; shift;;
        --backup-dir) BACKUP_DIR_MODE="readonly"; shift;;
        --overwrite) OVERWRITE=1; shift;;
        --checksum) USE_CHECKSUM=1; shift;;
        --help) mostrar_ayuda; exit 0;;
        *) echo "ERROR: Opción desconocida: $1"; mostrar_ayuda; exit 1;;
    esac
done

[ -z "$MODO" ] && { echo "ERROR: Debes especificar --subir o --bajar"; mostrar_ayuda; exit 1; }

# =========================
# Run
# =========================
verificar_dependencias
find_config_files
verificar_archivos_configuracion
inicializar_log

# Limpieza de temporales al salir
trap 'if [ "${#TEMP_FILES[@]}" -gt 0 ]; then rm -f "${TEMP_FILES[@]}" 2>/dev/null || true; fi' EXIT

sincronizar
resultado=$?

if [ "$MODO" = "bajar" ] && [ $DRY_RUN -eq 0 ]; then
    ajustar_permisos_ejecutables \
        ".local/bin/*.sh" \
        ".local/bin/*.bash" \
        ".local/bin/pcloud" \
        ".config/dotfiles/*.sh"
elif [ "$MODO" = "bajar" ] && [ $DRY_RUN -eq 1 ]; then
    echo "Modo simulación: Se omitió el ajuste de permisos de ejecución (solo aplica en modo --bajar)"
fi

echo ""
echo "=========================================="
if [ $resultado -eq 0 ]; then
    if [ $DRY_RUN -eq 1 ]; then
        echo "✓ Simulación completada exitosamente"
        registrar_log "Simulación completada exitosamente"
    else
        echo "✓ Sincronización completada exitosamente"
        registrar_log "Sincronización completada exitosamente"
    fi
else
    echo "✗ Sincronización completada con errores"
    registrar_log "Sincronización completada con errores"
fi
echo "Log guardado en: $LOG_FILE"
echo "=========================================="

