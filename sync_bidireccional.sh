#!/bin/bash

# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud
# Uso:
#   Subir: ./sync_bidireccional.sh --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
#   Bajar: ./sync_bidireccional.sh --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite] [--recreate-symlinks]

# ---------------------------------------------------------------------------------------------------
# Configuración - ¡Modifica estas rutas según tu caso!
# ---------------------------------------------------------------------------------------------------
PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"
LOCAL_DIR="${HOME}"
PCLOUD_BACKUP_COMMON="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

# Hostname de la máquina y de la máquina especial
HOSTNAME=$(hostname)
HOSTNAME_RTVA="feynman.rtva.dnf"

# Archivos de configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_LIST_FILE=""
EXCLUSION_FILE=""
LOG_FILE="$HOME/sync_bidireccional.log"
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

# Variables de control
MODE=""
DRY_RUN=0
DELETE=0
ITEM_TO_SYNC=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="common" # Opciones: "common" | "readonly"
RECREATE_SYMLINKS=0

# Definición de códigos de color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------------------------------
# Funciones
# ---------------------------------------------------------------------------------------------------

# Muestra el menú de ayuda
show_help() {
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones PRINCIPALES (obligatoria una de ellas):"
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
    echo "  --help             Muestra esta ayuda"
    echo ""
    echo "Archivos de configuración:"
    echo "  - Directorio del script: ${SCRIPT_DIR}/"
    echo "  - Directorio actual: $(pwd)/"
    if [ "$HOSTNAME" = "$HOSTNAME_RTVA" ]; then
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
    echo "  ./sync_bidireccional.sh --bajar --backup-dir --item documentos/ --yes"
}

# Determina el directorio de pCloud según el modo
get_pcloud_dir() {
    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMMON"
    fi
}

# Busca los archivos de configuración
find_config_files() {
    local default_list="sync_bidireccional_directorios.ini"
    local specific_list="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"
    local exclusion_file="sync_bidireccional_exclusiones.ini"

    # Determina el archivo de lista
    local list_to_find="${default_list}"
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        list_to_find="${specific_list}"
    fi

    if [ -f "${SCRIPT_DIR}/${list_to_find}" ]; then
        SYNC_LIST_FILE="${SCRIPT_DIR}/${list_to_find}"
    elif [ -f "./${list_to_find}" ]; then
        SYNC_LIST_FILE="./${list_to_find}"
    fi

    # Busca el archivo de exclusiones
    if [ -f "${SCRIPT_DIR}/${exclusion_file}" ]; then
        EXCLUSION_FILE="${SCRIPT_DIR}/${exclusion_file}"
    elif [ -f "./${exclusion_file}" ]; then
        EXCLUSION_FILE="./${exclusion_file}"
    fi
}

# Verifica que las dependencias necesarias estén instaladas
check_dependencies() {
    if ! command -v rsync &> /dev/null; then
        echo -e "${RED}ERROR: rsync no está instalado. Por favor, instálalo.${NC}"
        exit 1
    fi
}

# Inicializa el archivo de log
init_log() {
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    echo "========================================================" >> "$LOG_FILE"
    echo "Sincronización iniciada: $(date)" >> "$LOG_FILE"
    echo "Modo: $MODE, Borrado: $DELETE, Simulación: $DRY_RUN, Sobrescritura: $OVERWRITE" >> "$LOG_FILE"
    if [ -n "$ITEM_TO_SYNC" ]; then
        echo "Elemento específico: $ITEM_TO_SYNC" >> "$LOG_FILE"
    fi
    echo "--------------------------------------------------------" >> "$LOG_FILE"
}

# Registra un mensaje en el archivo de log
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Verifica si pCloud está montado y accesible
verify_pcloud_mount() {
    local pcloud_dir=$(get_pcloud_dir)
    echo -e "${YELLOW}Verificando punto de montaje de pCloud...${NC}"
    if [ ! -d "$PCLOUD_MOUNT_POINT" ]; then
        echo -e "${RED}ERROR: El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT${NC}"
        echo "Asegúrate de que pCloud Drive esté instalado y ejecutándose."
        exit 1
    fi
    if ! mount | grep -q "pCloud\|pcloud"; then
        echo -e "${RED}ERROR: pCloud no aparece en la lista de sistemas de archivos montados.${NC}"
        echo "Asegúrate de que pCloud Drive esté ejecutándose y montado."
        exit 1
    fi
    if [ ! -d "$pcloud_dir" ]; then
        echo -e "${RED}ERROR: El directorio de pCloud no existe: $pcloud_dir${NC}"
        echo "Verifica que el directorio exista en tu pCloud."
        exit 1
    fi
    echo -e "${GREEN}✓ Verificación de pCloud completada. El directorio está montado y accesible.${NC}"
}

# Muestra el banner informativo con las opciones seleccionadas
show_banner() {
    local pcloud_dir=$(get_pcloud_dir)
    echo -e "${BLUE}==========================================${NC}"
    if [ "$MODE" = "subir" ]; then
        echo -e "${BLUE}MODO: SUBIR (Local → pCloud)${NC}"
        echo "  - Origen: ${LOCAL_DIR}"
        echo "  - Destino: ${pcloud_dir}"
    else
        echo -e "${BLUE}MODO: BAJAR (pCloud → Local)${NC}"
        echo "  - Origen: ${pcloud_dir}"
        echo "  - Destino: ${LOCAL_DIR}"
    fi
    echo -e "${BLUE}------------------------------------------${NC}"
    [ $DRY_RUN -eq 1 ] && echo -e "  - Estado: ${GREEN}MODO SIMULACIÓN${NC} (no se realizarán cambios)"
    [ $DELETE -eq 1 ] && echo -e "  - Borrado: ${GREEN}ACTIVADO${NC} (se eliminarán archivos obsoletos)"
    [ $YES -eq 1 ] && echo -e "  - Confirmación: ${GREEN}Automática${NC}"
    [ $OVERWRITE -eq 1 ] && echo -e "  - Sobrescritura: ${GREEN}ACTIVADA${NC} (se sobrescribirán todos los archivos)"
    [ $OVERWRITE -eq 0 ] && echo -e "  - Modo: ${GREEN}SEGURO${NC} (--update activado, se preservan archivos más recientes)"
    [ -n "$ITEM_TO_SYNC" ] && echo "  - Elemento: $ITEM_TO_SYNC"
    [ -n "$SYNC_LIST_FILE" ] && echo "  - Lista: ${SYNC_LIST_FILE}"
    [ -n "$EXCLUSION_FILE" ] && echo "  - Exclusiones: ${EXCLUSION_FILE}"
    echo -e "${BLUE}==========================================${NC}"
}

# Pide confirmación al usuario antes de proceder
confirm_execution() {
    if [ $YES -eq 1 ]; then
        echo -e "${YELLOW}Confirmación automática (--yes): se procede con la sincronización.${NC}"
        return
    fi
    echo ""
    read -p "¿Deseas continuar con la sincronización? [s/N]: " response
    if [ "$response" != "s" ] && [ "$response" != "S" ]; then
        echo "Operación cancelada por el usuario."
        exit 0
    fi
    echo ""
}

# Construye la cadena de opciones de rsync
build_rsync_options() {
    local options="--archive --verbose --progress"
    
    # --archive es equivalente a -rlptgoD
    # --no-links se incluye para evitar que rsync maneje enlaces simbólicos directamente
    options="$options --no-links"

    if [ $OVERWRITE -eq 0 ]; then
        options="$options --update"
    fi
    if [ $DRY_RUN -eq 1 ]; then
        options="$options --dry-run"
    fi
    if [ $DELETE -eq 1 ]; then
        options="$options --delete-delay"
    fi

    # Añadir exclusiones si el archivo existe
    if [ -n "$EXCLUSION_FILE" ] && [ -f "$EXCLUSION_FILE" ]; then
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                options="$options --exclude='${line}'"
            fi
        done < "$EXCLUSION_FILE"
    fi
    echo "$options"
}

# ---------------------------------------------------------------------------------------------------
# Funciones para el manejo de enlaces simbólicos
# ---------------------------------------------------------------------------------------------------

# Genera el archivo de metadatos de enlaces simbólicos
generate_symlinks_metafile() {
    local item_path="$1"
    local target_dir="${LOCAL_DIR}/${item_path}"
    local temp_file=$(mktemp)
    local pcloud_dir=$(get_pcloud_dir)

    echo -e "${YELLOW}Generando archivo de metadatos para enlaces simbólicos...${NC}"
    log_message "Generando archivo de metadatos de enlaces simbólicos."
    
    # Busca enlaces simbólicos en el directorio de destino
    find "${target_dir}" -type l -print0 | while IFS= read -r -d '' symlink; do
        local relative_path=""
        local target_path=""
        local target_real_path=""

        # Obtener la ruta relativa del enlace simbólico directamente del path de 'find'
        relative_path="${symlink#${LOCAL_DIR}/}"
        
        # Obtener la ruta de destino del enlace usando 'readlink'
        target_path=$(readlink "$symlink")

        # Determinar si el destino existe y obtener su ruta absoluta.
        if [[ "$target_path" != /* ]]; then
            # Si el destino es relativo, resuélvelo desde el directorio del enlace.
            target_real_path=$(realpath "$(dirname "$symlink")/$target_path" 2>/dev/null)
        else
            # Si el destino es absoluto, verifica su existencia.
            target_real_path=$(realpath "$target_path" 2>/dev/null)
        fi

        # Si el destino no es válido, es un enlace roto.
        if [ ! -e "$target_real_path" ]; then
            echo -e "${YELLOW}ADVERTENCIA: Enlace simbólico roto, omitiendo: ${symlink}${NC}"
            log_message "ADVERTENCIA: Enlace simbólico roto: ${symlink}"
            continue
        fi
        
        # Si todo es correcto, añadir al archivo temporal.
        echo -e "${relative_path}\t${target_real_path}" >> "$temp_file"
    done

    # Sincroniza el archivo de metadatos con pCloud
    if [ -s "$temp_file" ]; then
        echo -e "${YELLOW}Sincronizando archivo de metadatos con pCloud...${NC}"
        local meta_file_dest="${pcloud_dir}/${SYMLINKS_FILE}"
        
        if [ $DRY_RUN -eq 1 ]; then
            echo "SIMULACIÓN: Se sincronizaría el archivo de enlaces simbólicos a: ${meta_file_dest}"
            log_message "SIMULACIÓN: Sincronización de metadatos de enlaces."
        else
            cp -f "$temp_file" "${meta_file_dest}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Archivo de metadatos de enlaces sincronizado exitosamente.${NC}"
                log_message "Archivo de metadatos sincronizado: ${meta_file_dest}"
            else
                echo -e "${RED}✗ Error sincronizando el archivo de metadatos de enlaces.${NC}"
                log_message "Error sincronizando el archivo de metadatos."
            fi
        fi
    else
        echo "No se encontraron enlaces simbólicos válidos para registrar."
        log_message "No se encontraron enlaces simbólicos válidos para registrar."
    fi

    rm -f "$temp_file"
}

# Recrea los enlaces simbólicos a partir del archivo de metadatos
recreate_symlinks_from_metafile() {
    local pcloud_dir=$(get_pcloud_dir)
    local remote_meta_file="${pcloud_dir}/${SYMLINKS_FILE}"
    local local_meta_file="${LOCAL_DIR}/${SYMLINKS_FILE}"
    local created_count=0
    local error_count=0

    echo -e "${YELLOW}Recreando enlaces simbólicos a partir del archivo de metadatos...${NC}"
    log_message "Iniciando recreación de enlaces simbólicos."

    if [ ! -f "$remote_meta_file" ]; then
        echo "No se encontró el archivo de metadatos de enlaces en pCloud. Omitiendo la recreación."
        log_message "Archivo de metadatos no encontrado en pCloud. Operación omitida."
        return
    fi
    
    # Copia el archivo remoto al directorio local para su procesamiento
    cp "$remote_meta_file" "$local_meta_file"

    while IFS=$'\t' read -r relative_path target; do
        local full_path="${LOCAL_DIR}/${relative_path}"
        local parent_dir=$(dirname "$full_path")

        # Verifica si el enlace ya existe y es correcto
        if [ -L "$full_path" ] && [ "$(readlink -f "$full_path")" = "$target" ]; then
            echo -e "${GREEN}✓ Enlace simbólico ya existe y es correcto: '${full_path}'${NC}"
            log_message "Enlace ya existente y correcto: '${full_path}'"
            continue
        fi
        
        if [ $DRY_RUN -eq 1 ]; then
            echo "SIMULACIÓN: Se crearía el enlace simbólico: '${full_path}' -> '${target}'"
            log_message "SIMULACIÓN: Enlace: '${full_path}' -> '${target}'"
            ((created_count++))
        else
            mkdir -p "$parent_dir"
            if ln -sfn "$target" "$full_path"; then
                echo -e "${GREEN}✓ Creado enlace simbólico: '${full_path}'${NC}"
                log_message "Creado enlace: '${full_path}' -> '${target}'"
                ((created_count++))
            else
                echo -e "${RED}✗ ERROR al crear el enlace: '${full_path}'${NC}"
                log_message "Error al crear enlace: '${full_path}' -> '${target}'"
                ((error_count++))
            fi
        fi
    done < "$local_meta_file"

    echo "Resumen: Creados/actualizados: ${created_count}, Errores: ${error_count}"
    log_message "Recreación de enlaces finalizada. Creados: $created_count, Errores: $error_count"
    
    # Limpia el archivo temporal
    if [ $DRY_RUN -eq 0 ]; then
        rm -f "$local_meta_file"
    fi
}

# ---------------------------------------------------------------------------------------------------
# Funciones principales de ejecución
# ---------------------------------------------------------------------------------------------------

# Sincroniza un solo elemento (directorio o archivo)
sync_item() {
    local item="$1"
    local rsync_opts="$2"
    local pcloud_dir=$(get_pcloud_dir)
    local origen=""
    local destino=""
    local direction=""

    if [ "$MODE" = "subir" ]; then
        origen="${LOCAL_DIR}/${item}"
        destino="${pcloud_dir}/${item}"
        direction="LOCAL → PCLOUD"
    else
        origen="${pcloud_dir}/${item}"
        destino="${LOCAL_DIR}/${item}"
        direction="PCLOUD → LOCAL"
    fi
    
    if [ ! -e "$origen" ]; then
        echo -e "${YELLOW}ADVERTENCIA: El origen no existe, omitiendo: ${origen}${NC}"
        log_message "ADVERTENCIA: Origen no existe, omitiendo: ${origen}"
        return 1
    fi

    # Normalizar rutas para rsync
    if [ -d "$origen" ]; then
        origen="${origen}/"
        destino="${destino}/"
    fi

    echo -e "${BLUE}▶ Sincronizando: ${item} (${direction})${NC}"
    log_message "Sincronizando: ${item} (${direction})"

    local rsync_command="rsync ${rsync_opts} '${origen}' '${destino}'"
    echo "  - Comando: ${rsync_command}"
    log_message "Comando ejecutado: ${rsync_command}"

    eval "${rsync_command}"
    local result=$?

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}✓ Sincronización completada para: ${item}${NC}"
        log_message "Sincronización completada para: ${item}"
    else
        echo -e "${RED}✗ Error en la sincronización de: ${item} (código: ${result})${NC}"
        log_message "Error en la sincronización de: ${item} (código: ${result})"
    fi
    return $result
}

# Función principal de sincronización
run_sync() {
    local rsync_opts=$(build_rsync_options)
    local exit_code=0
    
    show_banner
    verify_pcloud_mount
    
    # Pide confirmación si no es dry-run
    if [ $DRY_RUN -eq 0 ]; then
        confirm_execution
    fi

    # Si se especificó un elemento, se sincroniza ese elemento y se generan los enlaces
    if [ -n "$ITEM_TO_SYNC" ]; then
        if [ "$MODE" = "subir" ]; then
            generate_symlinks_metafile "$ITEM_TO_SYNC"
        fi
        sync_item "$ITEM_TO_SYNC" "$rsync_opts"
        exit_code=$?
    else
        # Si no se especifica un item, se usa la lista de sincronización
        if [ -z "$SYNC_LIST_FILE" ]; then
            echo -e "${RED}ERROR: No se encontró un archivo de lista de sincronización.${NC}"
            echo "Asegúrate de tener el archivo '${HOSTNAME_RTVA}.ini' o 'directorios.ini' en el directorio del script o en el directorio actual, o usa la opción --item."
            exit 1
        fi
        
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                if [ "$MODE" = "subir" ]; then
                    generate_symlinks_metafile "$line"
                fi
                sync_item "$line" "$rsync_opts"
                if [ $? -ne 0 ]; then
                    exit_code=1
                fi
                echo "------------------------------------------"
            fi
        done < "$SYNC_LIST_FILE"
    fi
    
    # Recrea los enlaces simbólicos si el modo es "bajar"
    if [ "$MODE" = "bajar" ]; then
        recreate_symlinks_from_metafile
    fi

    return $exit_code
}

# Ajusta permisos de ejecución a los scripts
set_exec_permissions() {
    local patterns=(".local/bin/*.sh" ".local/bin/*.bash" ".local/bin/*.py" ".local/bin/pcloud" ".config/dotfiles/*.sh")
    local exit_status=0

    echo -e "${YELLOW}Ajustando permisos de ejecución...${NC}"
    log_message "Ajustando permisos de ejecución."

    for pattern in "${patterns[@]}"; do
        local full_path="${LOCAL_DIR}/${pattern}"
        if compgen -G "$full_path" > /dev/null; then
            find "${LOCAL_DIR}/$(dirname "$pattern")" -maxdepth 1 -name "$(basename "$pattern")" -type f -exec chmod +x {} +
        else
            echo "ADVERTENCIA: No se encontró ningún archivo para el patrón: $full_path"
            exit_status=1
        fi
    done
    return $exit_status
}

# ---------------------------------------------------------------------------------------------------
# Lógica principal del script
# ---------------------------------------------------------------------------------------------------

# Procesar argumentos de línea de comandos
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subir)
            if [ -n "$MODE" ]; then echo "ERROR: Solo se puede especificar --subir o --bajar."; show_help; exit 1; fi
            MODE="subir"; shift ;;
        --bajar)
            if [ -n "$MODE" ]; then echo "ERROR: Solo se puede especificar --subir o --bajar."; show_help; exit 1; fi
            MODE="bajar"; shift ;;
        --delete)
            DELETE=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --item)
            if [ $# -lt 2 ]; then echo "ERROR: La opción --item requiere un argumento."; show_help; exit 1; fi
            ITEM_TO_SYNC="$2"; shift 2 ;;
        --yes)
            YES=1; shift ;;
        --backup-dir)
            BACKUP_DIR_MODE="readonly"; shift ;;
        --overwrite)
            OVERWRITE=1; shift ;;
        --help)
            show_help; exit 0 ;;
        *)
            echo "ERROR: Opción desconocida: $1"; show_help; exit 1 ;;
    esac
done

# Validaciones iniciales
if [ -z "$MODE" ]; then
    echo -e "${RED}ERROR: Debes especificar --subir o --bajar.${NC}"; show_help; exit 1
fi
if [ -z "$ITEM_TO_SYNC" ]; then
    find_config_files
    if [ -z "$SYNC_LIST_FILE" ]; then
        echo -e "${RED}ERROR: No se encontró el archivo de lista de sincronización.${NC}"
        echo "Asegúrate de tener el archivo '${HOSTNAME_RTVA}.ini' o 'directorios.ini' en el directorio del script o en el directorio actual, o usa la opción --item."
        exit 1
    fi
fi

# Iniciar el proceso
check_dependencies
init_log
run_sync
sync_result=$?

# Ejecutar la función de permisos solo al bajar
if [ "$MODE" = "bajar" ] && [ $DRY_RUN -eq 0 ]; then
    set_exec_permissions
fi

echo ""
echo "==========================================="
if [ $sync_result -eq 0 ]; then
    echo -e "${GREEN}✓ Sincronización completada exitosamente.${NC}"
    log_message "Sincronización completada exitosamente."
else
    echo -e "${RED}✗ Sincronización finalizada con errores.${NC}"
    log_message "Sincronización finalizada con errores."
fi
echo "Log guardado en: $LOG_FILE"
echo "==========================================="
